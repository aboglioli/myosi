#!/usr/bin/env bash
set -euo pipefail

# Stage the LUKS bootstrap key at keys/data.key (mkosi.postinst ships
# it in-image + on the ESP; the initrd pulls it via ExtraTrees=).
# Resolution: $MYOSI_DATA_KEY (CI secret, base64 of 32 raw bytes) →
# existing keys/data.key → fresh `openssl rand 32`.
# Must stay STABLE across releases: a per-build key would leave LUKS
# slot 0 bound to the old key after a sysupdate UKI swap — data lockout
# unless the operator already wiped slot 0 (cryptsetup luksKillSlot).
# Treat leaks like signing-key leaks: every install with slot 0 intact
# is exposed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KEY_DST="${ROOT}/keys/data.key"

mkdir -p "$(dirname "$KEY_DST")"
chmod 700 "$(dirname "$KEY_DST")" 2>/dev/null || true

source_mode=""

if [ -n "${MYOSI_DATA_KEY:-}" ]; then
    source_mode="env (MYOSI_DATA_KEY)"
    echo "$MYOSI_DATA_KEY" | base64 -d > "$KEY_DST"
elif [ -s "$KEY_DST" ]; then
    source_mode="cached"
    # leave it alone
else
    source_mode="generated"
    openssl rand 32 > "$KEY_DST"
fi

chmod 0600 "$KEY_DST"

bytes=$(stat -c %s "$KEY_DST")
if [ "$bytes" -ne 32 ]; then
    echo "ERROR: $KEY_DST is $bytes bytes, expected 32." >&2
    echo "If MYOSI_DATA_KEY was set, it likely wasn't base64 of 32 raw bytes." >&2
    echo "Regenerate with: openssl rand 32 | base64 -w0" >&2
    exit 1
fi

echo "Bootstrap LUKS key staged at $KEY_DST"
echo "  source: $source_mode"
