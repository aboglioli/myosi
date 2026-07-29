#!/usr/bin/env bash
set -euo pipefail

# Decode base64-encoded signing keys from GitHub Actions secrets and stage
# them at keys/. The mkosi configs reference keys/* unconditionally, so the
# key material source determines whether a build is local or release-signed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Keys land at <repo>/keys/ — exactly ONE level up from this script's
# dir. mkosi reads keys/ relative to the project root; a wrong level
# aborts the build at cert validation ("Failed to load X.509
# certificate"). mkdir before resolving so `cd` succeeds on first run.
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
