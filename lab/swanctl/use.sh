#!/usr/bin/env bash
# Activates one configuration on this peer: credentials, connection, reload.
# Usage: sudo /opt/pqc-lab/swanctl/use.sh ini|resp <config-id> [--pfs]
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"
need_root

role="${1:-}"; id="${2:-}"
[ -n "$role" ] && [ -n "$id" ] || die "usage: $0 ini|resp <config-id> [--pfs]"
pki="$LAB_STATE_DIR/pki"
[ -f "$pki/$role.cert.pem" ] || die "no lab PKI in $pki (run swanctl/gen-certs.sh)"

install -m 600 "$pki/$role.key.pem"  /etc/swanctl/private/pqc-lab.key.pem
install -m 644 "$pki/$role.cert.pem" /etc/swanctl/x509/pqc-lab.cert.pem
install -m 644 "$pki/ca.cert.pem"    /etc/swanctl/x509ca/pqc-lab-ca.cert.pem
"$LAB/swanctl/render.sh" "$@" > /etc/swanctl/conf.d/pqc-active.conf
swanctl --load-all
info "active: $(grep -m1 'proposals' /etc/swanctl/conf.d/pqc-active.conf | xargs)"
