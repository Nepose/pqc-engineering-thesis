#!/usr/bin/env bash
# Step L2 on pqc-wan: router between the measured networks. Idempotent.
# Usage: sudo /opt/pqc-lab/provision/setup-wan.sh
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"
need_root

if ! command -v tcpdump >/dev/null || ! command -v nft >/dev/null || ! command -v ethtool >/dev/null; then
    info "installing tcpdump, nftables, ethtool"
    DEBIAN_FRONTEND=noninteractive apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends tcpdump nftables ethtool
fi

left="${PQC_LEFT_IF:-$(iface_in "$LEFT_NET")}"
right="${PQC_RIGHT_IF:-$(iface_in "$RIGHT_NET")}"
[ -n "$left" ] && [ -n "$right" ] || die "measured interfaces not found (set PQC_LEFT_IF / PQC_RIGHT_IF)"
info "left: $left, right: $right"

ip addr replace "$WAN_LEFT_IP/$PREFIX_LEN" dev "$left"
ip addr replace "$WAN_RIGHT_IP/$PREFIX_LEN" dev "$right"
sysctl -q -w net.ipv4.ip_forward=1 \
    net.ipv4.conf.all.send_redirects=0 \
    "net.ipv4.conf.$left.send_redirects=0" "net.ipv4.conf.$right.send_redirects=0"

# Captures must show packets as they cross the wire: no offload merging or splitting.
for ifc in "$left" "$right"; do
    for feature in gro gso tso lro; do
        ethtool -K "$ifc" "$feature" off 2>/dev/null || warn "$ifc: cannot turn $feature off"
    done
done

install -d -m 755 "$LAB_STATE_DIR"
printf 'WAN_LEFT_IF=%s\nWAN_RIGHT_IF=%s\n' "$left" "$right" > "$LAB_STATE_DIR/wan-ifaces.env"
info "interfaces recorded in $LAB_STATE_DIR/wan-ifaces.env (used by profiles/apply.sh)"
