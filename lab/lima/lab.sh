#!/usr/bin/env bash
# Host-side lifecycle of the test bed (macOS + Lima). Run from anywhere.
#
# Usage: lab/lima/lab.sh <command>
#   networks       create the measured networks pqc-left / pqc-right (option A, lab/README.md)
#   base           create and start pqc-base and copy lab/ into it
#   build          build strongSwan and the lab PKI inside pqc-base (step L1)
#   peers          clone pqc-base into pqc-ini / pqc-resp, attach networks, set up addressing
#   wan            create pqc-wan on both networks and set it up as the router
#   sync           copy lab/ into every running lab VM (after editing scripts)
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

exists()  { limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$1"; }
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
        if limactl network list | awk 'NR > 1 { print $1 }' | grep -qx "$name"; then
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

cmd_sync() {
    local vm
    for vm in "${LAB_VMS[@]}"; do running "$vm" && push_lab "$vm"; done
    return 0
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
    status)        cmd_status ;;
    stop)          cmd_stop ;;
    destroy-peers) cmd_destroy_vms pqc-ini pqc-resp ;;
    destroy)       cmd_destroy_vms "${LAB_VMS[@]}" ;;
    *) sed -n '2,16p' "$0"; exit 1 ;;
esac
