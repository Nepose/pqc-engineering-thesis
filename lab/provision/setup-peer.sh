#!/usr/bin/env bash
# Step L2 on a peer: static address, routes via pqc-wan, "lan" namespace.
# Idempotent; run again after a reboot.
# Usage: sudo /opt/pqc-lab/provision/setup-peer.sh ini|resp
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"
need_root

case "${1:-}" in
    ini)  my_ip="$INI_IP";  my_net="$LEFT_NET";  via="$WAN_LEFT_IP"
          far_net="$RIGHT_NET"; far_lan="$RESP_LAN"; lan_gw="$INI_LAN_GW";  lan_host="$INI_LAN_HOST" ;;
    resp) my_ip="$RESP_IP"; my_net="$RIGHT_NET"; via="$WAN_RIGHT_IP"
          far_net="$LEFT_NET";  far_lan="$INI_LAN";  lan_gw="$RESP_LAN_GW"; lan_host="$RESP_LAN_HOST" ;;
    *)    die "usage: $0 ini|resp" ;;
esac

ifc="${PQC_IF:-$(iface_in "$my_net")}"
[ -n "$ifc" ] || die "no interface with an address in $my_net (set PQC_IF)"
info "measured interface: $ifc"

ip addr replace "$my_ip/$PREFIX_LEN" dev "$ifc"
# Lima's DHCP address stays primary (SSH needs it), so pin the lab address as source.
ip route replace "$far_net" via "$via" dev "$ifc" src "$my_ip"
ip route replace "$far_lan" via "$via" dev "$ifc" src "$my_ip"
sysctl -q -w net.ipv4.ip_forward=1 \
    net.ipv4.conf.all.accept_redirects=0 "net.ipv4.conf.$ifc.accept_redirects=0"

# Hosts behind the gateway
ip netns list | grep -qw lan || ip netns add lan
if ! ip link show veth-gw >/dev/null 2>&1; then
    ip link add veth-gw type veth peer name veth-lan
    ip link set veth-lan netns lan
fi
ip addr replace "$lan_gw/24" dev veth-gw
ip link set veth-gw up
ip netns exec lan ip link set lo up
ip netns exec lan ip addr replace "$lan_host/24" dev veth-lan
ip netns exec lan ip link set veth-lan up
ip netns exec lan ip route replace default via "$lan_gw"

info "route to the peer: $(ip route get "${far_net%.*}.100" | head -n1)"
