#!/usr/bin/env bash
# Steps L3/L4: one configuration end to end, and what it puts on the wire.
# Run on the macOS host once the peers run strongSwan (lab/README.md, L1-L2).
# Usage: lab/checks/tunnel-check.sh <config-id> [<profile> ...]
#   lab/checks/tunnel-check.sh c1
#   lab/checks/tunnel-check.sh p1024 mtu1280
# Report: results/tunnel/<id>[-<profiles>]-<UTC>.txt (in git).
# Raw files: results/raw/tunnel/<same name>/: both pcaps, the session keys, the charon
# logs (ignored by git; the keys decrypt the captures).
# At the end the tunnel is torn down and pqc-wan goes back to the lan profile.
# Exit code 0 = all checks PASS.
#
#   1 up        initiate succeeds and the CHILD_SA is INSTALLED
#   2 proposal  the IKE SA uses exactly the configuration's key exchange
#   3 traffic   5 pings between the LAN namespaces get through
#   4 esp       pqc-wan sees ESP and no plaintext LAN traffic
#   5 iperf3    TCP through the tunnel for 3 s (throughput reported, not judged)
#
# This is a functional check, not a measurement: one run, no repetitions, and the
# initiate time includes swanctl and VICI overhead (the measurement client is L6).
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$LAB/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"

id="${1:-}"
[ -n "$id" ] || { sed -n '2,20p' "$0"; exit 1; }
shift
profiles=("$@")
[ "${#profiles[@]}" -gt 0 ] || profiles=(lan)
ke="$(awk -F'\t' -v id="$id" '$1 !~ /^#/ && $1 == id { print $2 }' "$LAB/swanctl/matrix.tsv")"
[ -n "$ke" ] || die "unknown configuration '$id' (see lab/swanctl/matrix.tsv)"
# matrix notation -> swanctl --list-sas notation: x25519-ke1_mlkem768 -> CURVE_25519/KE1_ML_KEM_768
expect="$(sed -E -e 's/-ke([1-7])_/\/KE\1_/g' -e 's/x25519/CURVE_25519/g' \
                 -e 's/ecp256/ECP_256/g' -e 's/mlkem([0-9]+)/ML_KEM_\1/g' <<<"$ke")"

name="$id"
[ "${profiles[*]}" = lan ] || name="$id-$(IFS=-; echo "${profiles[*]}")"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
raw="$REPO/results/raw/tunnel/$name-$stamp"
mkdir -p "$raw" "$REPO/results/tunnel"
report="$REPO/results/tunnel/$name-$stamp.txt"
exec > >(tee "$report") 2>&1

vm() { local vm_name="$1"; shift; limactl shell --workdir / "$vm_name" sudo bash -c "$*"; }
failed=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failed=1; }

echo "tunnel check $id ($ke), profile ${profiles[*]}, $(date -u +%FT%TZ)"
echo "scripts: commit $(git -C "$REPO" rev-parse --short HEAD)$(git -C "$REPO" diff --quiet HEAD -- lab || echo ' + uncommitted changes in lab/')"
echo "daemon:  $(vm pqc-ini 'swanctl --version')"
echo "raw:     ${raw#"$REPO"/}"
echo

"$LAB/lima/lab.sh" clock >/dev/null
vm pqc-wan "$LAB_VM_DIR/profiles/apply.sh ${profiles[*]}" >/dev/null
eval "$(vm pqc-wan "cat $LAB_STATE_DIR/wan-ifaces.env")"

# Fresh daemons: no SAs left over, key files only from this run.
for role in resp ini; do
    vm "pqc-$role" "systemctl restart strongswan && rm -f $LAB_STATE_DIR/wireshark/* \
        && $LAB_VM_DIR/swanctl/use.sh $role $id" >/dev/null
done
log_ini="$(vm pqc-ini "wc -l < $LAB_LOG_DIR/charon.log")"
log_resp="$(vm pqc-resp "wc -l < $LAB_LOG_DIR/charon.log")"

# One capture per interface of pqc-wan, as transient units so they outlive the ssh session.
# The filter also takes plaintext LAN traffic, so a leak past the tunnel would show up.
# --immediate-mode: without it the kernel holds packets for up to 1 s and stopping the
# unit loses the last ones.
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

echo "== 1 up"
read -r rc ms <<<"$(vm pqc-ini "s=\$(date +%s%N)
    swanctl --initiate --child $id-lan --timeout 30 > /tmp/pqc-initiate.log 2>&1 && rc=0 || rc=\$?
    echo \$rc \$(( (\$(date +%s%N) - s) / 1000000 ))")"
sas="$(vm pqc-ini "swanctl --list-sas --ike $id" || true)"
sed 's/^/  /' <<<"$sas"
if [ "$rc" = 0 ] && grep -q INSTALLED <<<"$sas"; then
    pass "CHILD_SA installed; swanctl --initiate returned after $ms ms"
else
    fail "initiate exit code $rc after $ms ms"
    vm pqc-ini "tail -n 15 /tmp/pqc-initiate.log" | sed 's/^/  /'
fi

echo "== 2 proposal"
ike_line="$(grep -m1 -E '^ +[A-Z0-9_-]+/PRF_' <<<"$sas" | xargs || true)"
if [ -n "$ike_line" ] && [[ "$ike_line" == *"/$expect" ]]; then
    pass "IKE proposal $ike_line"
else
    fail "IKE proposal '$ike_line', expected the key exchange $expect"
fi

echo "== 3 traffic"
pings="$(vm pqc-ini "ip netns exec lan ping -n -c 5 -i 0.2 -W 5 $RESP_LAN_HOST" 2>&1 || true)"
got="$(sed -nE 's/.* ([0-9]+) received.*/\1/p' <<<"$pings")"
if [ "${got:-0}" -ge 5 ]; then pass "$INI_LAN_HOST -> $RESP_LAN_HOST: ${got}/5 replies"; else fail "${got:-0}/5 ping replies"; fi

vm pqc-wan "systemctl stop pqc-capture-left pqc-capture-right"

echo "== 4 esp"
esp="$(vm pqc-wan "tcpdump -n -r /tmp/pqc-left.pcap esp 2>/dev/null | wc -l" | xargs)"
plain="$(vm pqc-wan "tcpdump -n -r /tmp/pqc-left.pcap 'net $INI_LAN or net $RESP_LAN' 2>/dev/null | wc -l" | xargs)"
if [ "$esp" -ge 10 ] && [ "$plain" -eq 0 ]; then
    pass "$esp ESP packets on pqc-wan, $plain plaintext LAN packets"
else
    fail "$esp ESP packets on pqc-wan, $plain plaintext LAN packets"
fi

echo "== 5 iperf3 (not captured)"
if [ "${got:-0}" -eq 0 ]; then
    fail "skipped: no traffic gets through"
else
    vm pqc-resp "pkill -x iperf3 || true; ip netns exec lan iperf3 -s -1 -D; sleep 0.5"
    tput="$(vm pqc-ini "ip netns exec lan iperf3 -c $RESP_LAN_HOST -t 3 -f m --connect-timeout 3000" 2>&1 |
        awk '/receiver/ { print $(NF-2), $(NF-1) }' || true)"
    if [ -n "$tput" ]; then pass "TCP through the tunnel: $tput"; else fail "iperf3 did not complete"; fi
fi

# Tear down and collect the raw files.
vm pqc-ini "swanctl --terminate --ike $id --timeout 10" >/dev/null 2>&1 || true
vm pqc-wan "$LAB_VM_DIR/profiles/apply.sh lan" >/dev/null
limactl cp pqc-wan:/tmp/pqc-left.pcap "$raw/left.pcap"
limactl cp pqc-wan:/tmp/pqc-right.pcap "$raw/right.pcap"
vm pqc-ini "tar -C $LAB_STATE_DIR/wireshark -cf - ." | tar -C "$raw" -xf -
vm pqc-ini "cat /tmp/pqc-initiate.log" > "$raw/initiate.log"
vm pqc-ini "tail -n +$((log_ini + 1)) $LAB_LOG_DIR/charon.log" > "$raw/charon-ini.log"
vm pqc-resp "tail -n +$((log_resp + 1)) $LAB_LOG_DIR/charon.log" > "$raw/charon-resp.log"

echo
echo "== on the wire: pqc-left, the initiator's side of pqc-wan, decrypted with the session keys"
vm pqc-wan "rm -rf /tmp/pqc-keys && mkdir -m 700 /tmp/pqc-keys"
vm pqc-ini "tar -C $LAB_STATE_DIR/wireshark -cf - ." | vm pqc-wan "tar -C /tmp/pqc-keys -xf -"
vm pqc-wan "$LAB_VM_DIR/checks/ike-table.sh /tmp/pqc-left.pcap /tmp/pqc-keys; rm -rf /tmp/pqc-keys"
echo
echo "== pqc-right, the responder's side: $(vm pqc-wan "tcpdump -n -r /tmp/pqc-right.pcap 2>/dev/null | wc -l" | xargs) frames, $(vm pqc-wan "tcpdump -n -r /tmp/pqc-right.pcap 'ip[6:2] & 0x3fff != 0' 2>/dev/null | wc -l" | xargs) of them IP fragments"

echo
if [ "$failed" -eq 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: some checks failed"; fi
echo "report: ${report#"$REPO"/}"
exit "$failed"
