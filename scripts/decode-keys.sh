#!/usr/bin/env bash
set -euo pipefail

# Decode base64-encoded signing keys from GitHub Actions secrets and stage
# them at keys/. The mkosi configs reference keys/* unconditionally, so the
# key material source determines whether a build is local or release-signed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Keys always land in myosi/keys/ regardless of where this script lives.
# When this script lived at myosi/ci/lib/decode-keys.sh, `../..` resolved
# to myosi/ (correct). After the move to myosi/scripts/decode-keys.sh,
# the same `../..` now resolves to the repo root (one level too high) —
# the CI build for 2026.06.07.03 aborted with
#   Failed to load X.509 certificate from /keys/image.crt: No such file
# because mkosi reads keys at myosi/keys/ and the keys had landed at
# <repo>/keys/ instead. Compute DST as one step up from this script's
# own dir, mkdir before resolving so `cd` succeeds on first run.
DST="${SCRIPT_DIR}/../keys"
mkdir -p "$DST"
chmod 700 "$DST"
DST="$(cd "$DST" && pwd)"

decode() {
    local var="$1" dst="$2"
    if [ -z "${!var:-}" ]; then
        echo "ERROR: env var $var is empty" >&2
        return 1
    fi
    echo "${!var}" | base64 -d > "$dst"
}

decode MYOSI_BOOT_KEY   "$DST/boot.key"
decode MYOSI_BOOT_CRT   "$DST/boot.crt"
decode MYOSI_IMAGE_KEY  "$DST/image.key"
decode MYOSI_IMAGE_CRT  "$DST/image.crt"

chmod 600 "$DST/boot.key" "$DST/image.key"
chmod 644 "$DST/boot.crt" "$DST/image.crt"

echo "Signing keys staged at $DST"
