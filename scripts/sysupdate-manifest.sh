#!/usr/bin/env bash
set -euo pipefail

# Generate a JSON manifest of all artifacts in the build directory.
# Usage: sysupdate-manifest.sh <artifacts-dir>

ARTIFACTS_DIR="${1:-build}"
cd "$ARTIFACTS_DIR"

echo "{"
echo "  \"generated_at\": \"$(date -u -Iseconds)\","
echo "  \"artifacts\": ["

FIRST=1
for f in $(find . -type f \( \
        -name '*.raw' -o -name '*.raw.xz' -o -name '*.raw.zst' \
        -o -name '*.efi' -o -name '*.efi.zst' \
        -o -name '*.verity' -o -name '*.verity-sig' \
        -o -name '*.part??' \
    \) | sort); do
    NAME=$(basename "$f")
    SIZE=$(stat -c%s "$f")
    SHA=$(sha256sum "$f" | awk '{print $1}')
    [ "$FIRST" = 1 ] || echo ","
    FIRST=0
    printf '    {"name": "%s", "size": %d, "sha256": "%s"}' "$NAME" "$SIZE" "$SHA"
done
echo
echo "  ]"
echo "}"
