#!/usr/bin/env bash
# Network profiles on pqc-wan, applied to the egress of each interface (one per direction).
# Usage: sudo /opt/pqc-lab/profiles/apply.sh <profile> [<profile> ...]
#        LOSS=1 sudo .../apply.sh ltem mtu1280      (loss in % per direction, default 0)
#        sudo .../apply.sh show
# Every call starts from a clean state ("lan") and applies the profiles left to right.
#
#   lan       no impairment, MTU 1500 (baseline)
#   ltem      LTE-M-like:  one-way delay 50 ms (RTT ~100 ms), 1 Mbit/s
#   nbiot     NB-IoT-like: one-way delay 750 ms (RTT ~1.5 s), 60 kbit/s
#   mtu1280   1280-byte MTU bottleneck in the middle of the path (peers stay at 1500)
#   fragdrop  drop every IPv4 fragment, like a fragment-hostile firewall or NAT
#
# TODO(P3): cite a source for every value in chapter 5.
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"
need_root

. "$LAB_STATE_DIR/wan-ifaces.env" 2>/dev/null || die "run provision/setup-wan.sh first"
ifaces=("$WAN_LEFT_IF" "$WAN_RIGHT_IF")
LOSS="${LOSS:-0}"

clear_all() {
    local ifc
    for ifc in "${ifaces[@]}"; do
        tc qdisc del dev "$ifc" root 2>/dev/null || true
        ip link set dev "$ifc" mtu 1500
    done
    nft delete table inet pqclab 2>/dev/null || true
}

netem_both() {
    local ifc
    for ifc in "${ifaces[@]}"; do tc qdisc replace dev "$ifc" root netem "$@"; done
}

show() {
    local ifc
    for ifc in "${ifaces[@]}"; do
        ip -br link show dev "$ifc"
        tc qdisc show dev "$ifc"
    done
    nft list table inet pqclab 2>/dev/null || echo "(no fragment filter)"
}

[ "$#" -gt 0 ] || { sed -n '2,14p' "$0"; exit 1; }
if [ "$1" = show ]; then show; exit 0; fi

clear_all
for profile in "$@"; do
    case "$profile" in
        lan)      ;;
        ltem)     netem_both delay 50ms rate 1mbit loss "${LOSS}%" ;;
        nbiot)    netem_both delay 750ms rate 60kbit loss "${LOSS}%" ;;
        mtu1280)  for ifc in "${ifaces[@]}"; do ip link set dev "$ifc" mtu 1280; done ;;
        fragdrop)
            # Hooked before conntrack's defragmentation (priority -400), so fragments are still visible.
            nft -f - <<'EOF'
table inet pqclab {
    chain prerouting {
        type filter hook prerouting priority -450; policy accept;
        ip frag-off & 0x3fff != 0 counter drop
    }
}
EOF
            ;;
        *) die "unknown profile: $profile" ;;
    esac
    info "applied $profile"
done
show
