# Helpers shared by the lab scripts. Source after lab.env.

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "warning: $*" >&2; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; }

# Interface with an IPv4 address in the given /24. Lima's DHCP puts one there
# before the static lab addresses exist; callers accept PQC_*IF overrides.
iface_in() {
    local prefix="${1%.*}."  # 10.10.1.0/24 -> 10.10.1.
    ip -o -4 addr show | awk -v p="$prefix" 'index($4, p) == 1 { print $2; exit }'
}

# Addresses and routes added with "ip" are foreign to systemd-networkd, which removes them
# whenever it restarts. On 2026-11-19 unattended-upgrades restarted it in every lab VM, and
# the lab lost its path without any error. A drop-in for the interface's .network file
# makes networkd configure them itself, so they survive a restart.
networkd_dropin() {
    local ifc="$1" conf="$2" file dir
    file="$(networkctl status "$ifc" 2>/dev/null | awk '/Network File:/ { print $3 }')"
    [ -n "$file" ] && [ "$file" != "n/a" ] || die "$ifc is not managed by systemd-networkd"
    dir="/etc/systemd/network/$(basename "$file").d"
    install -d -m 755 "$dir"
    printf '# Written by lab/provision: lab state that must survive a networkd restart.\n%s\n' \
        "$conf" > "$dir/50-pqc-lab.conf"
    info "networkd drop-in: $dir/50-pqc-lab.conf"
}

# Package versions of the lab VMs for the report headers, run on the host by a check that
# defines vm(). strongSwan is built from source and reported separately (swanctl --version).
PEER_VERSIONS='printf "kernel %s" "$(uname -r)"; dpkg-query -W -f=", \${Package} \${Version}" libc6 libssl3t64'
WAN_VERSIONS='printf "kernel %s" "$(uname -r)"; dpkg-query -W -f=", \${Package} \${Version}" iproute2 tcpdump tshark'
print_versions() {
    local ini resp wan
    ini="$(vm pqc-ini "$PEER_VERSIONS")"
    resp="$(vm pqc-resp "$PEER_VERSIONS")"
    wan="$(vm pqc-wan "$WAN_VERSIONS")"
    echo "system:  ini  $ini"
    echo "         resp $resp"
    echo "         wan  $wan"
    [ "$ini" = "$resp" ] || warn "pqc-ini and pqc-resp run different package versions"
}
