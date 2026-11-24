#!/usr/bin/env bash
# No automatic package changes in a lab VM. unattended-upgrades changes the software under
# test between runs: on 2026-11-19 it upgraded libc6, installed a new kernel and restarted
# systemd-networkd. Packages now change only by hand, and every report records the versions
# (lab/README.md, "Pin and record versions"). Acceptable for an isolated lab VM only.
# Idempotent. Usage: sudo /opt/pqc-lab/provision/freeze-packages.sh
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"
need_root

# Sorted after 20auto-upgrades, so these values win.
cat > /etc/apt/apt.conf.d/99pqc-lab-no-auto-upgrades <<'EOF'
// Lab VM: no automatic package lists or upgrades (lab/provision/freeze-packages.sh).
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
# Masked rather than disabled, so a package update cannot enable them again.
systemctl mask --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
systemctl disable --now unattended-upgrades.service >/dev/null 2>&1 || true
info "automatic upgrades off (apt timers: $(systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer 2>/dev/null | sort -u | xargs))"
