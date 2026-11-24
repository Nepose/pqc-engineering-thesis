#!/usr/bin/env bash
# Step L5: one rekeying procedure for one configuration, and what it puts on the wire.
# Run on the macOS host once tunnel-check.sh passes for the configuration (L3-L4).
# Usage: lab/checks/rekey-check.sh <config-id> <scenario> [<profile> ...]
#   s2  Child SA rekey without a key exchange        swanctl --rekey --child
#   s3  Child SA rekey with a key exchange (PFS)     use.sh ... --pfs, then swanctl --rekey --child
#   s4  IKE SA rekey (a key exchange is mandatory)   swanctl --rekey --ike
#   s5  reauthentication: a new IKE SA from scratch  swanctl --rekey --ike --reauth
#   lab/checks/rekey-check.sh h768 s3
# Report: results/rekey/<id>-<scenario>[-<profiles>]-<UTC>.txt (in git).
# Raw files: results/raw/rekey/<same name>/: both pcaps, the session keys, the charon logs
# (ignored by git; the keys decrypt the captures).
# The capture starts once the tunnel is up, so it holds the procedure itself and the pings
# that test the new SAs. At the end the tunnel is torn down and pqc-wan goes back to lan.
# Exit code 0 = all checks PASS.
#
#   1 up        the tunnel is up before the procedure
#   2 rekey     the procedure replaces the SA (new SPIs) and the old SA is deleted
#   3 traffic   5 pings between the LAN namespaces get through, ESP only, on the new SPIs
#   4 wire      the decrypted capture holds the exchanges RFC 7296 and RFC 9370 predict:
#               s2 CREATE_CHILD_SA without KE; s3, s4 CREATE_CHILD_SA with the first key
#               exchange plus one IKE_FOLLOWUP_KE per additional one; s5 IKE_SA_INIT, one
#               IKE_INTERMEDIATE per additional key exchange, IKE_AUTH
#
# This is a functional check, not a measurement: one run, no repetitions.
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$LAB/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"

id="${1:-}"; scen="${2:-}"
[ -n "$id" ] && [ -n "$scen" ] || { sed -n '2,26p' "$0"; exit 1; }
shift 2
profiles=("$@")
[ "${#profiles[@]}" -gt 0 ] || profiles=(lan)
ke="$(awk -F'\t' -v id="$id" '$1 !~ /^#/ && $1 == id { print $2 }' "$LAB/swanctl/matrix.tsv")"
[ -n "$ke" ] || die "unknown configuration '$id' (see lab/swanctl/matrix.tsv)"
case "$scen" in
    s2) rekey="--rekey --child $id-lan"; pfs="" ;;
    s3) rekey="--rekey --child $id-lan"; pfs="--pfs" ;;
    s4) rekey="--rekey --ike $id";       pfs="" ;;
    s5) rekey="--rekey --ike $id --reauth"; pfs="" ;;
    *)  die "scenario must be s2, s3, s4 or s5" ;;
esac
# x25519-ke1_mlkem768 -> first key exchange x25519, additional ones: mlkem768
first="${ke%%-*}"
adds=()
[[ "$ke" != *-ke* ]] || read -r -a adds <<<"$(tr '-' '\n' <<<"${ke#*-}" | sed -E 's/^ke[1-7]_//' | xargs)"

"$LAB/lima/lab.sh" net-check >/dev/null

name="$id-$scen"
[ "${profiles[*]}" = lan ] || name="$name-$(IFS=-; echo "${profiles[*]}")"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
raw="$REPO/results/raw/rekey/$name-$stamp"
mkdir -p "$raw" "$REPO/results/rekey"
report="$REPO/results/rekey/$name-$stamp.txt"
exec > >(tee "$report") 2>&1

vm() { local vm_name="$1"; shift; limactl shell --workdir / "$vm_name" sudo bash -c "$*"; }
failed=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failed=1; }
# From swanctl --list-sas: the initiator's IKE SPI, and the inbound and outbound ESP SPIs.
ike_spi()   { sed -nE 's/.*ESTABLISHED, IKEv2, ([0-9a-f]+)_i.*/\1/p' <<<"$1" | xargs; }
# Only the INSTALLED Child SA counts: right after a rekey the old one is still listed as DELETED.
child_spi() {
    awk -v d="$2" '/, reqid / { on = /INSTALLED, TUNNEL/ }
        on && $1 == d && $2 ~ /^[0-9a-f]+,?$/ { sub(/,$/, "", $2); print $2 }' <<<"$1" | xargs
}

echo "rekey check $id ($ke), scenario $scen (swanctl $rekey${pfs:+, ESP proposal with $pfs}), profile ${profiles[*]}, $(date -u +%FT%TZ)"
echo "scripts: commit $(git -C "$REPO" rev-parse --short HEAD)$(git -C "$REPO" diff --quiet HEAD -- lab || echo ' + uncommitted changes in lab/')"
echo "daemon:  $(vm pqc-ini 'swanctl --version')"
print_versions
echo "raw:     ${raw#"$REPO"/}"
echo

"$LAB/lima/lab.sh" clock >/dev/null
vm pqc-wan "$LAB_VM_DIR/profiles/apply.sh ${profiles[*]}" >/dev/null
eval "$(vm pqc-wan "cat $LAB_STATE_DIR/wan-ifaces.env")"

# Fresh daemons: no SAs left over, key files only from this run.
for role in resp ini; do
    vm "pqc-$role" "systemctl restart strongswan && rm -f $LAB_STATE_DIR/wireshark/* \
        && $LAB_VM_DIR/swanctl/use.sh $role $id $pfs" >/dev/null
done
log_ini="$(vm pqc-ini "wc -l < $LAB_LOG_DIR/charon.log")"
log_resp="$(vm pqc-resp "wc -l < $LAB_LOG_DIR/charon.log")"

echo "== 1 up"
if vm pqc-ini "swanctl --initiate --child $id-lan --timeout 30" > "$raw/initiate.log" 2>&1; then rc=0; else rc=$?; fi
before="$(vm pqc-ini "swanctl --list-sas --ike $id" || true)"
sed 's/^/  /' <<<"$before"
if [ "$rc" = 0 ] && grep -q INSTALLED <<<"$before"; then
    pass "tunnel up before the procedure"
else
    fail "initiate exit code $rc"
fi
ike0="$(ike_spi "$before")"; in0="$(child_spi "$before" in)"

# Capture only from here on, as in tunnel-check.sh (transient units, --immediate-mode).
filter="(host $INI_IP and host $RESP_IP) or net $INI_LAN or net $RESP_LAN"
vm pqc-wan "
    for side in left right; do
        systemctl stop pqc-capture-\$side 2>/dev/null || true
        systemctl reset-failed pqc-capture-\$side 2>/dev/null || true
        rm -f /tmp/pqc-\$side.pcap
    done
    systemd-run --quiet --unit=pqc-capture-left  tcpdump -n -U --immediate-mode -i $WAN_LEFT_IF  -w /tmp/pqc-left.pcap  '$filter'
    systemd-run --quiet --unit=pqc-capture-right tcpdump -n -U --immediate-mode -i $WAN_RIGHT_IF -w /tmp/pqc-right.pcap '$filter'
    for i in \$(seq 50); do
        [ -s /tmp/pqc-left.pcap ] && [ -s /tmp/pqc-right.pcap ] && exit 0
        sleep 0.1
    done
    echo 'the captures did not start' >&2; exit 1"

echo "== 2 rekey"
vm pqc-ini "swanctl $rekey" > "$raw/rekey.log" 2>&1 || true
sed 's/^/  /' "$raw/rekey.log"
# swanctl only queues the procedure; wait until the new SA is up and the old one is gone.
after=""; done_=0
for _ in $(seq 60); do
    sleep 0.25
    after="$(vm pqc-ini "swanctl --list-sas --ike $id" || true)"
    n_ike="$(grep -c 'ESTABLISHED, IKEv2' <<<"$after" || true)"
    n_child="$(grep -c 'INSTALLED, TUNNEL' <<<"$after" || true)"
    # Any other state but DELETED means the procedure is still running.
    busy="$(grep -E ', reqid ' <<<"$after" | grep -vcE 'INSTALLED, TUNNEL|DELETED, TUNNEL' || true)"
    [ "$n_ike" = 1 ] && [ "$n_child" = 1 ] && [ "$busy" = 0 ] || continue
    case "$scen" in
        s2|s3) [ "$(child_spi "$after" in)" != "$in0" ] && { done_=1; break; } ;;
        s4|s5) [ "$(ike_spi "$after")" != "$ike0" ] && { done_=1; break; } ;;
    esac
done
sed 's/^/  /' <<<"$after"
ike1="$(ike_spi "$after")"; in1="$(child_spi "$after" in)"; out1="$(child_spi "$after" out)"
if [ "$done_" = 1 ]; then
    pass "IKE SPI $ike0 -> $ike1, inbound ESP SPI $in0 -> $in1, old SA deleted"
else
    fail "no single new SA after 15 s (IKE SPI $ike0 -> ${ike1:-?}, inbound ESP SPI $in0 -> ${in1:-?})"
fi
if [ "$scen" = s3 ]; then
    child_ke="$(grep 'INSTALLED, TUNNEL' <<<"$after" | grep -m1 -oE 'ESP:[A-Za-z0-9_/-]+' || true)"
    expect="$(sed -E -e 's/-ke([1-7])_/\/KE\1_/g' -e 's/x25519/CURVE_25519/g' \
                     -e 's/ecp256/ECP_256/g' -e 's/mlkem([0-9]+)/ML_KEM_\1/g' <<<"$ke")"
    if [[ "$child_ke" == *"/$expect" ]]; then pass "new Child SA $child_ke"; else fail "new Child SA '$child_ke', expected the key exchange $expect"; fi
fi

echo "== 3 traffic"
pings="$(vm pqc-ini "ip netns exec lan ping -n -c 5 -i 0.2 -W 5 $RESP_LAN_HOST" 2>&1 || true)"
got="$(sed -nE 's/.* ([0-9]+) received.*/\1/p' <<<"$pings")"
sleep 0.5
vm pqc-wan "systemctl stop pqc-capture-left pqc-capture-right"
spis="$(vm pqc-wan "tcpdump -n -r /tmp/pqc-left.pcap esp 2>/dev/null" | sed -nE 's/.*ESP\(spi=0x0*([0-9a-f]+),.*/\1/p' | sort -u | xargs)"
plain="$(vm pqc-wan "tcpdump -n -r /tmp/pqc-left.pcap 'net $INI_LAN or net $RESP_LAN' 2>/dev/null | wc -l" | xargs)"
norm() { printf '%x' "0x${1:-0}"; }
stray=""
for s in $spis; do [ "$(norm "$s")" = "$(norm "$in1")" ] || [ "$(norm "$s")" = "$(norm "$out1")" ] || stray="$stray $s"; done
if [ "${got:-0}" -ge 5 ] && [ "$plain" -eq 0 ] && [ -n "$spis" ] && [ -z "$stray" ]; then
    pass "${got}/5 replies, ESP SPIs on pqc-wan: $spis, $plain plaintext LAN packets"
else
    fail "${got:-0}/5 replies, ESP SPIs on pqc-wan: ${spis:-none} (not the new SAs:${stray:- none}), $plain plaintext LAN packets"
fi

# Tear down and collect the raw files.
vm pqc-ini "swanctl --terminate --ike $id --timeout 10" >/dev/null 2>&1 || true
vm pqc-wan "$LAB_VM_DIR/profiles/apply.sh lan" >/dev/null
limactl cp pqc-wan:/tmp/pqc-left.pcap "$raw/left.pcap"
limactl cp pqc-wan:/tmp/pqc-right.pcap "$raw/right.pcap"
vm pqc-ini "tar -C $LAB_STATE_DIR/wireshark -cf - ." | tar -C "$raw" -xf -
vm pqc-ini "tail -n +$((log_ini + 1)) $LAB_LOG_DIR/charon.log" > "$raw/charon-ini.log"
vm pqc-resp "tail -n +$((log_resp + 1)) $LAB_LOG_DIR/charon.log" > "$raw/charon-resp.log"

echo
echo "== on the wire: pqc-left, the initiator's side of pqc-wan, decrypted with the session keys"
vm pqc-wan "rm -rf /tmp/pqc-keys && mkdir -m 700 /tmp/pqc-keys"
vm pqc-ini "tar -C $LAB_STATE_DIR/wireshark -cf - ." | vm pqc-wan "tar -C /tmp/pqc-keys -xf -"
table="$(vm pqc-wan "$LAB_VM_DIR/checks/ike-table.sh /tmp/pqc-left.pcap /tmp/pqc-keys; rm -rf /tmp/pqc-keys")"
echo "$table"
echo
echo "== pqc-right, the responder's side: $(vm pqc-wan "tcpdump -n -r /tmp/pqc-right.pcap 2>/dev/null | wc -l" | xargs) frames, $(vm pqc-wan "tcpdump -n -r /tmp/pqc-right.pcap 'ip[6:2] & 0x3fff != 0' 2>/dev/null | wc -l" | xargs) of them IP fragments"

echo
echo "== 4 wire"
# The summary rows of ike-table.sh: "<exchange> <MID> req|resp  frames ... payloads  KE data".
summary="$(awk 'f; /^IKE message \(exchange MID\)/ { f = 1 }' <<<"$table")"
rows() { grep -E "^$1 [0-9a-f]+ $2 " <<<"$summary" || true; }
count() { local r; r="$(rows "$1" "$2")"; [ -z "$r" ] && echo 0 || wc -l <<<"$r" | xargs; }
n_add="${#adds[@]}"
case "$scen" in
    s2)
        ccs="$(rows CREATE_CHILD_SA req)"
        if [ "$(count CREATE_CHILD_SA req)" = 1 ] && [ "$(count CREATE_CHILD_SA resp)" = 1 ] \
           && ! grep -qw KE <<<"$ccs" && [ "$(count IKE_FOLLOWUP_KE req)" = 0 ]; then
            pass "one CREATE_CHILD_SA without KE, no IKE_FOLLOWUP_KE"
        else
            fail "expected one CREATE_CHILD_SA without KE and no IKE_FOLLOWUP_KE"
        fi ;;
    s3|s4)
        ok=1
        [ "$(count CREATE_CHILD_SA req)" = 1 ] && [ "$(count CREATE_CHILD_SA resp)" = 1 ] || ok=0
        rows CREATE_CHILD_SA req | grep -q " $first [0-9]* B" || ok=0
        rows CREATE_CHILD_SA resp | grep -q " $first [0-9]* B" || ok=0
        [ "$(count IKE_FOLLOWUP_KE req)" = "$n_add" ] && [ "$(count IKE_FOLLOWUP_KE resp)" = "$n_add" ] || ok=0
        for a in ${adds[@]+"${adds[@]}"}; do rows IKE_FOLLOWUP_KE req | grep -q " $a [0-9]* B" || ok=0; done
        if [ "$ok" = 1 ]; then
            pass "CREATE_CHILD_SA with $first, then $n_add IKE_FOLLOWUP_KE${adds[*]:+ (${adds[*]})}"
        else
            fail "expected CREATE_CHILD_SA with $first and $n_add IKE_FOLLOWUP_KE${adds[*]:+ (${adds[*]})}"
        fi ;;
    s5)
        ok=1
        rows IKE_SA_INIT req | grep -q " $first [0-9]* B" || ok=0
        [ "$(count IKE_INTERMEDIATE req)" = "$n_add" ] || ok=0
        [ "$(count IKE_AUTH resp)" = 1 ] || ok=0
        [ "$(count CREATE_CHILD_SA req)" = 0 ] || ok=0
        if [ "$ok" = 1 ]; then
            pass "new IKE_SA_INIT with $first, $n_add IKE_INTERMEDIATE, IKE_AUTH"
        else
            fail "expected IKE_SA_INIT with $first, $n_add IKE_INTERMEDIATE and IKE_AUTH"
        fi ;;
esac
dels="$(count INFORMATIONAL req)"
echo "      (INFORMATIONAL requests, e.g. deleting the old SA: $dels)"

echo
if [ "$failed" -eq 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: some checks failed"; fi
echo "report: ${report#"$REPO"/}"
exit "$failed"
