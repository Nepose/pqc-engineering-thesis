#!/usr/bin/env bash
# IoT device profile on pqc-ini: CPU and memory limits for the IKE daemon (cgroup v2).
# Usage: sudo /opt/pqc-lab/profiles/iot-cgroup.sh on|off|show
#        CPU_QUOTA=20% MEM_MAX=256M sudo .../iot-cgroup.sh on
# Runtime only. A quota throttles in bursts, so it only approximates a slower CPU.
set -euo pipefail
unit=strongswan.service
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

case "${1:-}" in
    on)   systemctl set-property --runtime "$unit" "CPUQuota=${CPU_QUOTA:-20%}" "MemoryMax=${MEM_MAX:-256M}" ;;
    off)  systemctl set-property --runtime "$unit" CPUQuota= MemoryMax=infinity ;;
    show) ;;
    *)    sed -n '2,5p' "$0"; exit 1 ;;
esac
systemctl show "$unit" -p CPUQuotaPerSecUSec -p MemoryMax
