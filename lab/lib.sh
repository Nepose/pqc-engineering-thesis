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
