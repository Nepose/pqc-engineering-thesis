#!/usr/bin/env bash
# Step L1: build strongSwan from a pinned release tarball inside pqc-base.
# Ubuntu 24.04 ships 5.9.13 (no ML-KEM, no RFC 9370), hence the source build.
# Usage (inside the VM): sudo /opt/pqc-lab/provision/build-strongswan.sh
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"
need_root

info "Installing build dependencies and lab tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
    build-essential pkg-config libssl-dev libsystemd-dev \
    curl ca-certificates bzip2 \
    iproute2 iperf3 tcpdump ethtool nftables python3 python3-venv

src=/usr/local/src
tarball="$src/strongswan-$STRONGSWAN_VERSION.tar.bz2"
mkdir -p "$src"
[ -f "$tarball" ] || curl -fL --retry 3 -o "$tarball" "$STRONGSWAN_URL"

actual="$(sha256sum "$tarball" | cut -d' ' -f1)"
if [ -z "$STRONGSWAN_SHA256" ]; then
    cat >&2 <<EOF
SHA-256 of $tarball:
  $actual
STRONGSWAN_SHA256 is empty in lab/lab.env. Verify the release signature first
(lab/README.md, step L1), pin this value, then run the script again.
EOF
    exit 2
fi
[ "$actual" = "$STRONGSWAN_SHA256" ] || die "checksum mismatch for $tarball: $actual"

info "Building strongSwan $STRONGSWAN_VERSION"
rm -rf "$src/strongswan-$STRONGSWAN_VERSION"
tar -xjf "$tarball" -C "$src"
cd "$src/strongswan-$STRONGSWAN_VERSION"
configure_flags=(
    --prefix=/usr
    --sysconfdir=/etc
    --with-systemdsystemunitdir=/usr/lib/systemd/system
    --enable-systemd
    --enable-swanctl
    --enable-vici
    --enable-openssl       # X25519, ECP, AES-GCM, SHA-2
    --enable-ml            # ML-KEM-512/768/1024
    --enable-save-keys     # writes IKE/ESP keys for Wireshark: LAB ONLY
    --enable-load-tester   # scenario S7
)
./configure "${configure_flags[@]}"
make -j"$(nproc)"
make install
ldconfig

info "Installing the lab configuration"
install -d -m 755 "$LAB_STATE_DIR" "$LAB_STATE_DIR/wireshark" "$LAB_LOG_DIR"
install -m 644 "$LAB/provision/strongswan-lab.conf" /etc/strongswan.d/zz-pqc-lab.conf
systemctl daemon-reload
systemctl enable --now strongswan.service

info "Recording build information in $LAB_STATE_DIR/build-info.txt"
{
    echo "date:       $(date -u +%FT%TZ)"
    echo "strongswan: $STRONGSWAN_VERSION (sha256 $STRONGSWAN_SHA256)"
    echo "configure:  ${configure_flags[*]}"
    echo "os:         $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "kernel:     $(uname -r)"
    echo "openssl:    $(openssl version)"
    echo "--- binaries (sha256)"
    sha256sum /usr/sbin/charon-systemd /usr/sbin/swanctl
    find /usr/lib/ipsec -type f -name '*.so*' | sort | xargs sha256sum
} > "$LAB_STATE_DIR/build-info.txt"

info "Done. Next: sudo $LAB/checks/build-check.sh"
