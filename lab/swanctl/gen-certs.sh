#!/usr/bin/env bash
# Lab PKI: ECDSA P-256 CA and one certificate per peer, generated once in pqc-base.
# Both clones inherit both keys, which is acceptable for a lab only.
# Usage: sudo /opt/pqc-lab/swanctl/gen-certs.sh
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"
need_root

out="$LAB_STATE_DIR/pki"
if [ -f "$out/ca.cert.pem" ]; then info "lab PKI already exists in $out"; exit 0; fi
install -d -m 700 "$out"
cd "$out"
umask 077

pki --gen --type ecdsa --size 256 --outform pem > ca.key.pem
pki --self --ca --lifetime 3650 --in ca.key.pem --type ecdsa \
    --dn "C=PL, O=PQC Lab, CN=PQC Lab Root CA" --outform pem > ca.cert.pem

for role in ini resp; do
    id="$INI_ID"; [ "$role" = resp ] && id="$RESP_ID"
    pki --gen --type ecdsa --size 256 --outform pem > "$role.key.pem"
    pki --pub --in "$role.key.pem" --type ecdsa \
        | pki --issue --lifetime 730 --cacert ca.cert.pem --cakey ca.key.pem \
              --dn "C=PL, O=PQC Lab, CN=$id" --san "$id" --outform pem > "$role.cert.pem"
done
chmod 644 ./*.cert.pem
info "lab PKI written to $out"
