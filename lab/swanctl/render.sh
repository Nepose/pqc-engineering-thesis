#!/usr/bin/env bash
# Prints the swanctl connection for one configuration from swanctl/matrix.tsv.
# Usage: render.sh ini|resp <config-id> [--pfs]
#   --pfs  key exchange in the ESP proposal too (Child SA rekey with KE, S3); use on both peers
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"

# Constant across all configurations, so that only the key exchange varies.
IKE_BASE="aes256gcm16-prfsha384"
ESP_BASE="aes256gcm16"

role="${1:-}"; id="${2:-}"; pfs="${3:-}"
[ -n "$role" ] && [ -n "$id" ] || die "usage: $0 ini|resp <config-id> [--pfs]"
[ -z "$pfs" ] || [ "$pfs" = "--pfs" ] || die "unknown option: $pfs"

row="$(awk -F'\t' -v id="$id" '$1 !~ /^#/ && $1 == id' "$LAB/swanctl/matrix.tsv")"
[ -n "$row" ] || die "unknown configuration '$id' (see swanctl/matrix.tsv)"
ke="$(cut -f2 <<<"$row")"
note="$(cut -f3 <<<"$row")"

ike="$IKE_BASE-$ke"
esp="$ESP_BASE"
[ "$pfs" = "--pfs" ] && esp="$ESP_BASE-$ke" && note="$note, ESP with PFS"

case "$role" in
    ini)  local_addr="$INI_IP";  remote_addr="$RESP_IP"; local_id="$INI_ID";  remote_id="$RESP_ID"
          local_ts="$INI_LAN";  remote_ts="$RESP_LAN" ;;
    resp) local_addr="$RESP_IP"; remote_addr="%any";     local_id="$RESP_ID"; remote_id="$INI_ID"
          local_ts="$RESP_LAN"; remote_ts="$INI_LAN" ;;
    *)    die "role must be ini or resp" ;;
esac

sed -e "s|@ID@|$id|g" \
    -e "s|@ROLE_NOTE@|$role, $note|" \
    -e "s|@LOCAL_ADDR@|$local_addr|" \
    -e "s|@REMOTE_ADDR@|$remote_addr|" \
    -e "s|@IKE_PROPOSAL@|$ike|" \
    -e "s|@ESP_PROPOSAL@|$esp|" \
    -e "s|@LOCAL_ID@|$local_id|" \
    -e "s|@REMOTE_ID@|$remote_id|" \
    -e "s|@LOCAL_TS@|$local_ts|" \
    -e "s|@REMOTE_TS@|$remote_ts|" \
    "$LAB/swanctl/connection.conf.in"
