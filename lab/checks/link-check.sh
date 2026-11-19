#!/usr/bin/env bash
# Step L0: is the measured path through pqc-wan fit for IPsec measurements?
# Run on the macOS host after `lab.sh peers` and `lab.sh wan`. strongSwan is not needed.
# Usage: lab/checks/link-check.sh [--no-esp]
# Writes the report to results/l0/link-check-<UTC timestamp>.txt. Exit code 0 = all PASS.
#
#   0 route    the peers reach each other through pqc-wan
#   1 baseline 1000 pings at 10 ms: median RTT < 1 ms (p99 reported as the LAN baseline)
#   2 frags    3000-byte pings, fragmented by the sender, get through and are reassembled
#   3 mtu      with a 1280 MTU on pqc-wan, DF packets trigger "fragmentation needed"
#   4 netem    the ltem profile (50 ms one way) yields an RTT of ~100 ms
#   5 esp      plain ESP (IP protocol 50) passes; a manual transport-mode SA, ICMP only
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$LAB/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"

with_esp=1
[ "${1:-}" = "--no-esp" ] && with_esp=0

mkdir -p "$REPO/results/l0"
# A lab that has lost its addresses or routes still yields a plausible report, so refuse
# to start without them (lab.sh net-check).
"$LAB/lima/lab.sh" net-check >/dev/null

report="$REPO/results/l0/link-check-$(date -u +%Y%m%dT%H%M%SZ).txt"
exec > >(tee "$report") 2>&1

vm() { local name="$1"; shift; limactl shell --workdir / "$name" sudo bash -c "$*"; }
apply() { vm pqc-wan "$LAB_VM_DIR/profiles/apply.sh $*" >/dev/null; }

failed=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failed=1; }

# Median, p99 and count of the "time=" values in ping output (stdin).
rtt_stats() {
    awk -F'time=' '/time=/ { split($2, t, " "); print t[1] }' | sort -n | awk '
        { v[NR] = $1 }
        END {
            if (NR == 0) { print "n/a n/a 0"; exit }
            i = int(NR * 0.99); if (i < 1) i = 1
            print v[int((NR + 1) / 2)], v[i], NR
        }'
}
between() { awk -v x="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(x + 0 >= lo && x + 0 <= hi && x != "n/a") }'; }

echo "link check, $(date -u +%FT%TZ)"
echo "host: $(sysctl -n machdep.cpu.brand_string), lima $(limactl --version | awk '{print $3}')"
echo "path: pqc-ini $INI_IP -> pqc-wan -> pqc-resp $RESP_IP"
echo

echo "== 0 route"
route="$(vm pqc-ini "ip route get $RESP_IP")"
echo "$route" | head -n1
if grep -q "via $WAN_LEFT_IP" <<<"$route"; then pass "route via pqc-wan"; else fail "route does not go via $WAN_LEFT_IP"; fi

echo "== 1 baseline"
apply lan
read -r med p99 n <<<"$(vm pqc-ini "ping -n -i 0.01 -c 1000 $RESP_IP" | rtt_stats || true)"
echo "median $med ms, p99 $p99 ms, replies $n/1000"
if [ "$n" -ge 990 ] && between "$med" 0 1; then pass "baseline median $med ms, p99 $p99 ms"; else fail "baseline median $med ms, $n/1000 replies"; fi

echo "== 2 frags"
read -r med _ n <<<"$(vm pqc-ini "ping -n -M dont -s 3000 -i 0.2 -c 20 $RESP_IP" | rtt_stats || true)"
if [ "$n" -ge 19 ]; then pass "fragmented pings: $n/20 replies"; else fail "fragmented pings: $n/20 replies"; fi

echo "== 3 mtu"
apply mtu1280
out="$(vm pqc-ini "ping -n -M do -s 1400 -c 3 -W 1 $RESP_IP" 2>&1 || true)"
apply lan
vm pqc-ini "ip route flush cache" || true
if grep -Eq 'mtu ?= ?1280' <<<"$out"; then pass "ICMP fragmentation needed with mtu 1280"; else fail "no ICMP fragmentation needed seen"; echo "$out"; fi

echo "== 4 netem"
apply ltem
read -r med _ n <<<"$(vm pqc-ini "ping -n -i 0.2 -c 20 $RESP_IP" | rtt_stats || true)"
apply lan
if between "$med" 95 115; then pass "ltem RTT median $med ms (expected ~100)"; else fail "ltem RTT median $med ms (expected ~100)"; fi

if [ "$with_esp" -eq 1 ]; then
    echo "== 5 esp"
    # Static lab-only test key: 128-bit AES key + 32-bit salt for rfc4106(gcm(aes)).
    key=0x0102030405060708090a0b0c0d0e0f1011121314
    for side in ini resp; do
        src="$INI_IP"; dst="$RESP_IP"
        [ "$side" = resp ] && src="$RESP_IP" && dst="$INI_IP"
        vm "pqc-$side" "
            ip xfrm state add src $INI_IP dst $RESP_IP proto esp spi 0xa01 mode transport aead 'rfc4106(gcm(aes))' $key 128
            ip xfrm state add src $RESP_IP dst $INI_IP proto esp spi 0xa02 mode transport aead 'rfc4106(gcm(aes))' $key 128
            ip xfrm policy add src $src/32 dst $dst/32 proto icmp dir out tmpl src $src dst $dst proto esp mode transport"
    done
    capture="$(mktemp)"
    vm pqc-wan "timeout 10 tcpdump -n -l -i any -c 10 esp 2>/dev/null" > "$capture" &
    sleep 2
    read -r _ _ n <<<"$(vm pqc-ini "ping -n -i 0.2 -c 5 $RESP_IP" | rtt_stats || true)"
    wait || true
    esp="$(grep -c 'ESP' "$capture" || true)"
    rm -f "$capture"
    for side in ini resp; do
        src="$INI_IP"; dst="$RESP_IP"
        [ "$side" = resp ] && src="$RESP_IP" && dst="$INI_IP"
        vm "pqc-$side" "
            ip xfrm policy delete src $src/32 dst $dst/32 proto icmp dir out
            ip xfrm state delete src $INI_IP dst $RESP_IP proto esp spi 0xa01
            ip xfrm state delete src $RESP_IP dst $INI_IP proto esp spi 0xa02" || true
    done
    if [ "$n" -ge 5 ] && [ "$esp" -ge 8 ]; then pass "ESP: $esp packets on pqc-wan, $n/5 replies"; else fail "ESP: $esp packets on pqc-wan, $n/5 replies"; fi
fi

echo
if [ "$failed" -eq 0 ]; then echo "RESULT: all checks passed"; else echo "RESULT: some checks failed"; fi
echo "report: $report"
exit "$failed"
