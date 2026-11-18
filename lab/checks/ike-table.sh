#!/usr/bin/env bash
# Frame-by-frame view of an IKEv2/ESP capture, then one line per IKE message.
# Shows IP fragments, IKE fragments (RFC 7383), the payloads of each message and the
# key exchange data, so the cost of each configuration is visible on the wire.
# Runs where tshark is (pqc-wan).
# Usage: ike-table.sh <pcap> [<dir with ikev2_decryption_table and esp_sa from save-keys>]
# Without the key files the encrypted payloads (IKE_INTERMEDIATE, IKE_AUTH, ESP) stay
# opaque: sizes and fragments are still visible, the payloads inside them are not.
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"

pcap="${1:-}"; keys="${2:-}"
[ -f "$pcap" ] || die "usage: $0 <pcap> [<key dir>]"
command -v tshark >/dev/null || die "tshark not installed (provision/setup-wan.sh)"

# Private Wireshark profiles, so the key tables never touch a user's own settings.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Every additional key exchange (RFC 9370) derives new IKE keys for the same SPIs, and
# save-keys writes one line per derivation. Wireshark looks keys up by SPIs only, so
# decode once per generation of keys; each frame then keeps its fullest decode.
ike_table="${keys:+$keys/ikev2_decryption_table}"
generations=1
if [ -n "$ike_table" ] && [ -f "$ike_table" ]; then
    generations="$(awk -F, '{ n[$1 FS $2]++ } END { m = 1; for (k in n) if (n[k] > m) m = n[k]; print m }' "$ike_table")"
fi

fields=(frame.number frame.time_relative ip.src ip.dst ip.len ip.flags.mf ip.frag_offset ip.proto
        isakmp.exchangetype isakmp.flag_r isakmp.messageid isakmp.frag.number isakmp.frag.total
        isakmp.typepayload isakmp.key_exchange.dh_group isakmp.key_exchange.data icmp.type
        _ws.expert.message)
for gen in $(seq 1 "$generations"); do
    profile="$work/g$gen/wireshark"
    mkdir -p "$profile"
    if [ -n "$ike_table" ] && [ -f "$ike_table" ]; then
        awk -F, -v g="$gen" '{ c[$1 FS $2]++ } c[$1 FS $2] == g' "$ike_table" > "$profile/ikev2_decryption_table"
    fi
    # save-keys writes AES-GCM with "ANY <n> bit authentication". Wireshark 4.x wants
    # GCM with NULL authentication and the ICV length in the algorithm name; otherwise
    # it leaves the ESP payload encrypted.
    if [ -n "$keys" ] && [ -f "$keys/esp_sa" ]; then
        sed -E \
            -e 's/"AES-GCM \[RFC4106\]"(,"[^"]*",)"ANY 64 bit authentication \[no checking\]"/"AES-GCM with 8 octet ICV [RFC4106]"\1"NULL"/' \
            -e 's/"AES-GCM \[RFC4106\]"(,"[^"]*",)"ANY 96 bit authentication \[no checking\]"/"AES-GCM with 12 octet ICV [RFC4106]"\1"NULL"/' \
            -e 's/"AES-GCM \[RFC4106\]"(,"[^"]*",)"ANY 128 bit authentication \[no checking\]"/"AES-GCM with 16 octet ICV [RFC4106]"\1"NULL"/' \
            "$keys/esp_sa" > "$profile/esp_sa"
    fi
    XDG_CONFIG_HOME="$work/g$gen" tshark -n -r "$pcap" -o esp.enable_encryption_decode:TRUE \
        -T fields -E separator=/t -E occurrence=a -E aggregator=, "${fields[@]/#/-e}" \
        > "$work/decode.$gen" 2>/dev/null
done

# Per frame, the decode whose keys fit: a correct IKE integrity check, then the most fields.
# Wrong keys still "decrypt" into garbage payloads, but the ICV check flags them.
awk -F'\t' '
{
    c = 0; for (i = 1; i < NF; i++) if ($i != "") c++
    if ($NF ~ /Integrity Checksum Data is incorrect/) c -= 1000
    if (!($1 in score)) order[++n] = $1
    if (!($1 in score) || c > score[$1]) { score[$1] = c; row[$1] = $0 }
}
END { for (i = 1; i <= n; i++) print row[order[i]] }' "$work"/decode.* |
awk -F'\t' -v ini="$INI_IP" '
function first(s,  a) { split(s, a, ","); return a[1] }
function nth(s, i,  a) { split(s, a, ","); return a[i] }
function yes(s) { return s == "1" || s == "True" || s == "true" }
function mid(s) { sub(/^0x0*/, "", s); return s == "" ? "0" : s }
# Payload types after the outer SK/SKF, in strongSwan log style: "KE", "IDi CERT AUTH ..."
function payloads(s,  a, k, i, out, nn) {
    k = split(s, a, ","); out = ""; nn = 0
    for (i = 1; i <= k; i++) {
        if (a[i] == 46 || a[i] == 53 || a[i] == 2 || a[i] == 3) continue  # SK, SKF, proposal, transform
        if (a[i] == 41) { nn++; continue }
        out = out (out == "" ? "" : " ") (a[i] in p ? p[a[i]] : a[i])
    }
    if (nn) out = out (out == "" ? "" : " ") "N" (nn > 1 ? "x" nn : "")
    return out
}
function ke(grp, data) {
    if (grp == "") return ""
    gsub(/:/, "", data)
    return (first(grp) in g ? g[first(grp)] : "group " first(grp)) " " length(first(data)) / 2 " B"
}
BEGIN {
    x[34] = "IKE_SA_INIT"; x[35] = "IKE_AUTH"; x[36] = "CREATE_CHILD_SA"
    x[37] = "INFORMATIONAL"; x[43] = "IKE_INTERMEDIATE"; x[44] = "IKE_FOLLOWUP_KE"
    g[19] = "ecp256"; g[31] = "x25519"; g[35] = "mlkem512"; g[36] = "mlkem768"; g[37] = "mlkem1024"
    p[33] = "SA"; p[34] = "KE"; p[35] = "IDi"; p[36] = "IDr"; p[37] = "CERT"; p[38] = "CERTREQ"
    p[39] = "AUTH"; p[40] = "No"; p[42] = "D"; p[43] = "V"; p[44] = "TSi"; p[45] = "TSr"; p[47] = "CP"
    fmt = "%5s %9s %-4s %5s %-9s %-24s %-7s %-26s %s\n"
    printf fmt, "frame", "t [ms]", "from", "IP B", "IP frag", "IKE message", "IKE frg", "payloads", "KE data"
}
{
    t = sprintf("%.1f", $2 * 1000); from = first($3) == ini ? "ini" : "resp"; iplen = first($5)
    fragment = yes(first($6)) || first($7) + 0 > 0
    ipfrag = fragment ? "off " first($7) : ""
    if (first($8) == 50) {
        inner = nth($3, 2) != "" ? nth($3, 2) " > " nth($4, 2) ($17 != "" ? " ICMP" : "") : "(encrypted)"
        printf fmt, $1, t, from, iplen, ipfrag, "ESP", "", inner, ""
        esp[from]++; next
    }
    if ($9 == "") {
        printf fmt, $1, t, from, iplen, ipfrag, fragment ? "(IP fragment)" : (first($8) == 1 ? "ICMP" : "other"), "", "", ""
        if (fragment) { pend_b += iplen; pend_f++ }
        next
    }
    ex = first($9) in x ? x[first($9)] : "exchange " first($9)
    dir = yes(first($10)) ? "resp" : "req"
    key = ex " " mid(first($11)) " " dir
    frg = $12 != "" ? first($12) "/" first($13) : ""
    pl = payloads($14); kep = ke($15, $16)
    printf fmt, $1, t, from, iplen, ipfrag, ex " #" mid(first($11)) " " dir, frg, pl, kep
    if (!(key in bytes)) { order[++n] = key; start[key] = t }
    bytes[key] += iplen + pend_b; frames[key] += 1 + pend_f
    ipf[key] += pend_f + (fragment ? 1 : 0)
    if (frg != "") ikef[key]++
    if (pl != "") pls[key] = pl
    if (kep != "") kes[key] = kep
    last[key] = t; pend_b = 0; pend_f = 0
}
END {
    print ""
    sfmt = "%-28s %6s %8s %9s %7s  %-26s %s\n"
    printf sfmt, "IKE message (exchange MID)", "frames", "IP frags", "IKE frags", "bytes", "payloads", "KE data"
    for (i = 1; i <= n; i++) {
        k = order[i]
        printf sfmt, k, frames[k], ipf[k] ? ipf[k] : "-", ikef[k] ? ikef[k] : "-", bytes[k], pls[k], kes[k]
        tb += bytes[k]; tf += frames[k]
        if (k == "IKE_SA_INIT 0 req" && t0 == "") t0 = start[k]
        if (k ~ /^IKE_AUTH .* resp$/) t1 = last[k]
    }
    printf sfmt, "total IKE", tf, "", "", tb, "", ""
    if (t1 != "") printf "handshake on the wire (first IKE_SA_INIT request to IKE_AUTH response): %.1f ms\n", t1 - t0
    printf "ESP frames: %d from ini, %d from resp\n", esp["ini"], esp["resp"]
}'
