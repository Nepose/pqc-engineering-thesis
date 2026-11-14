#!/usr/bin/env bash
# Step L1 check: service, ML-KEM support, plugins. Exit code 0 = all PASS.
# Usage: sudo /opt/pqc-lab/checks/build-check.sh
set -euo pipefail
LAB="$(cd "$(dirname "$0")/.." && pwd)"
. "$LAB/lab.env"
. "$LAB/lib.sh"
need_root

failed=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; failed=1; }

swanctl --version
if systemctl is-active --quiet strongswan.service; then
    pass "strongswan.service is active"
else
    fail "strongswan.service is not active"
fi

algs="$(swanctl --list-algs)"
for params in 512 768 1024; do
    if grep -q "ML_KEM_$params" <<<"$algs"; then pass "ML-KEM-$params available"; else fail "ML-KEM-$params missing"; fi
done
if grep -q "CURVE_25519" <<<"$algs"; then pass "X25519 available"; else fail "X25519 missing"; fi

plugins="$(swanctl --stats | grep -A3 'loaded plugins' || true)"
for plugin in ml openssl vici save-keys; do
    if grep -qw -- "$plugin" <<<"$plugins"; then pass "plugin $plugin loaded"; else fail "plugin $plugin not loaded"; fi
done

echo "--- key exchange methods"
awk '/^(ke|dh):/ { on = 1; print; next } /^[a-z-]+:/ { on = 0 } on' <<<"$algs"

if [ -f "$LAB_STATE_DIR/build-info.txt" ]; then
    echo "--- build info"
    head -n 6 "$LAB_STATE_DIR/build-info.txt"
fi
exit "$failed"
