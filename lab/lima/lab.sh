#!/usr/bin/env bash
# Host-side lifecycle of the test bed (macOS + Lima). Run from anywhere.
#
# Usage: lab/lima/lab.sh <command>
#   networks       create the measured networks pqc-left / pqc-right (option A, lab/README.md)
#   base           create and start pqc-base, copy lab/ into it, turn automatic upgrades off
#   build          build strongSwan and the lab PKI inside pqc-base (step L1)
#   peers          clone pqc-base into pqc-ini / pqc-resp, attach networks, set up addressing
#   wan            create pqc-wan on both networks and set it up as the router
#   sync           copy lab/ into every running lab VM (after editing scripts)
#   net            re-apply addresses, routes and namespaces in the running VMs (after a reboot)
#   net-check      check that this state is in place (the checks run it first)
#   clock          set the clock of every running lab VM from the host clock
#   status         show lab VMs and networks; warn about other running VMs (noise)
#   stop           stop all lab VMs
#   destroy-peers  delete pqc-ini and pqc-resp (to re-clone after a new build)
#   destroy        delete all lab VMs
#
# Only VMs named pqc-* are ever touched.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="$(cd "$HERE/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"

LAB_VMS=(pqc-base pqc-ini pqc-resp pqc-wan)

# No "limactl ... | grep -q": grep exits on the first match, limactl gets SIGPIPE,
# and pipefail turns a found name into a failure.
exists()  { grep -qx "$1" <<<"$(limactl list --format '{{.Name}}' 2>/dev/null)"; }
running() { [ "$(limactl list --format '{{.Status}}' "$1" 2>/dev/null)" = "Running" ]; }
vm_root() { local vm="$1"; shift; limactl shell --workdir / "$vm" sudo "$@"; }

push_lab() {
    local vm="$1"
    info "copying lab/ into $vm:$LAB_VM_DIR"
    limactl shell --workdir / "$vm" rm -rf /tmp/pqc-lab
    limactl cp -r "$LAB" "$vm:/tmp/pqc-lab"
    vm_root "$vm" sh -c "rm -rf '$LAB_VM_DIR' && cp -r /tmp/pqc-lab '$LAB_VM_DIR'"
}

confirm() {
    local answer
    read -r -p "$1 Type 'delete' to continue: " answer
    [ "$answer" = "delete" ] || die "aborted"
}

cmd_networks() {
    local name cidr
    for name in "$NET_LEFT" "$NET_RIGHT"; do
        cidr="$NET_LEFT_GW_CIDR"; [ "$name" = "$NET_RIGHT" ] && cidr="$NET_RIGHT_GW_CIDR"
        if grep -qx "$name" <<<"$(limactl network list | awk 'NR > 1 { print $1 }')"; then
            info "network $name exists"
        else
            limactl network create "$name" --gateway "$cidr"
        fi
    done
}

cmd_base() {
    exists pqc-base || limactl create --tty=false --name pqc-base "$HERE/pqc-base.yaml"
    running pqc-base || limactl start pqc-base
    push_lab pqc-base
    vm_root pqc-base "$LAB_VM_DIR/provision/freeze-packages.sh"
}

cmd_build() {
    running pqc-base || die "pqc-base is not running (lab.sh base)"
    push_lab pqc-base
    vm_root pqc-base "$LAB_VM_DIR/provision/build-strongswan.sh"
    vm_root pqc-base "$LAB_VM_DIR/swanctl/gen-certs.sh"
    vm_root pqc-base "$LAB_VM_DIR/checks/build-check.sh"
}

cmd_peers() {
    exists pqc-ini || exists pqc-resp && die "peers already exist (lab.sh destroy-peers to re-clone)"
    exists pqc-base || die "pqc-base does not exist (lab.sh base)"
    running pqc-base && limactl stop pqc-base
    limactl clone --tty=false pqc-base pqc-ini --network "lima:$NET_LEFT" --start
    limactl clone --tty=false pqc-base pqc-resp --network "lima:$NET_RIGHT" --start
    local role
    for role in ini resp; do
        push_lab "pqc-$role"
        vm_root "pqc-$role" "$LAB_VM_DIR/provision/setup-peer.sh" "$role"
    done
}

cmd_wan() {
    exists pqc-wan || limactl create --tty=false --name pqc-wan \
        --network "lima:$NET_LEFT" --network "lima:$NET_RIGHT" "$HERE/pqc-wan.yaml"
    running pqc-wan || limactl start pqc-wan
    push_lab pqc-wan
    vm_root pqc-wan "$LAB_VM_DIR/provision/setup-wan.sh"
}

cmd_net() {
    local role
    vm_root pqc-wan "$LAB_VM_DIR/provision/setup-wan.sh"
    for role in ini resp; do
        vm_root "pqc-$role" "$LAB_VM_DIR/provision/setup-peer.sh" "$role"
    done
}

# The checks depend on runtime state that a VM can lose (a reboot, a networkd restart),
# and without it a run still writes a plausible report: on 2026-11-19 P768 over mtu1280
# "failed" because pqc-ini had lost its lab address.
net_check_peer() {
    local vm="$1" my_ip="$2" via="$3" peer_ip="$4" far_lan="$5" out ok=0
    running "$vm" || { warn "$vm is not running"; return 1; }
    out="$(vm_root "$vm" sh -c "ip -4 -o addr show; echo ROUTE \$(ip route get $peer_ip); \
        echo BLACKHOLE \$(ip route show type blackhole); echo NETNS \$(ip netns list)")"
    grep -q " $my_ip/" <<<"$out" || { warn "$vm: lab address $my_ip missing"; ok=1; }
    grep -q "^ROUTE .*via $via .*src $my_ip" <<<"$out" \
        || { warn "$vm: $peer_ip is not routed via $via from $my_ip"; ok=1; }
    grep -q "^BLACKHOLE .*${far_lan%/*}" <<<"$out" \
        || { warn "$vm: no blackhole route for $far_lan (the gateway would not fail closed)"; ok=1; }
    grep -Eq '^NETNS (.* )?lan( |$)' <<<"$out" || { warn "$vm: namespace lan missing"; ok=1; }
    return "$ok"
}

cmd_net_check() {
    local bad=0 out ip
    if running pqc-wan; then
        out="$(vm_root pqc-wan sh -c 'ip -4 -o addr show; echo FORWARD $(sysctl -n net.ipv4.ip_forward)')"
        for ip in "$WAN_LEFT_IP" "$WAN_RIGHT_IP"; do
            grep -q " $ip/" <<<"$out" || { warn "pqc-wan: lab address $ip missing"; bad=1; }
        done
        grep -q "^FORWARD 1" <<<"$out" || { warn "pqc-wan: IPv4 forwarding is off"; bad=1; }
    else
        warn "pqc-wan is not running"; bad=1
    fi
    net_check_peer pqc-ini  "$INI_IP"  "$WAN_LEFT_IP"  "$RESP_IP" "$RESP_LAN" || bad=1
    net_check_peer pqc-resp "$RESP_IP" "$WAN_RIGHT_IP" "$INI_IP"  "$INI_LAN"  || bad=1
    [ "$bad" = 0 ] || die "lab network state incomplete; restore it with lab/lima/lab.sh net"
    info "lab network state OK"
}

cmd_sync() {
    local vm
    for vm in "${LAB_VMS[@]}"; do running "$vm" && push_lab "$vm"; done
    return 0
}

# NTP gets no answer through the user-v2 networks, and a VM's clock stands still while
# the host sleeps. Durations always come from one clock (a pcap, a client), so a step of
# the wall clock only matters for matching logs across VMs; ssh latency bounds it to ~10 ms.
cmd_clock() {
    local vm now before
    for vm in "${LAB_VMS[@]}"; do
        running "$vm" || continue
        before="$(vm_root "$vm" date +%s.%N)"
        now="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
        vm_root "$vm" date -u -s "@$now" >/dev/null
        info "$vm: clock set from the host (was off by $(awk -v a="$before" -v b="$now" 'BEGIN { printf "%+.1f", a - b }') s)"
    done
}

cmd_status() {
    limactl list
    echo
    limactl network list
    local others
    others="$(limactl list --format '{{.Name}} {{.Status}}' | awk '$2 == "Running" && $1 !~ /^pqc-/ { print $1 }' | tr '\n' ' ')"
    [ -z "$others" ] || warn "other VMs are running (measurement noise): $others"
}

cmd_stop() {
    local vm
    for vm in "${LAB_VMS[@]}"; do running "$vm" && limactl stop "$vm"; done
    return 0
}

cmd_destroy_vms() {
    local vm targets=()
    for vm in "$@"; do exists "$vm" && targets+=("$vm"); done
    [ "${#targets[@]}" -gt 0 ] || { info "nothing to delete"; return 0; }
    confirm "This deletes: ${targets[*]}."
    for vm in "${targets[@]}"; do limactl delete -f "$vm"; done
}

case "${1:-}" in
    networks)      cmd_networks ;;
    base)          cmd_base ;;
    build)         cmd_build ;;
    peers)         cmd_peers ;;
    wan)           cmd_wan ;;
    sync)          cmd_sync ;;
    net)           cmd_net ;;
    net-check)     cmd_net_check ;;
    clock)         cmd_clock ;;
    status)        cmd_status ;;
    stop)          cmd_stop ;;
    destroy-peers) cmd_destroy_vms pqc-ini pqc-resp ;;
    destroy)       cmd_destroy_vms "${LAB_VMS[@]}" ;;
    *) sed -n '2,19p' "$0"; exit 1 ;;
esac
