#!/usr/bin/env bash
# Rename split artifacts to embed dm-verity-derived GPT PartitionUUIDs
# (DPS: root = first 16 bytes of the roothash, verity = last 16) so
# sysupdate's @u MatchPattern capture sets the destination
# PartitionUUID — without the rename, boots into the new slot hang in
# initrd waiting on /dev/disk/by-partuuid/. MUST run after `mkosi
# build` completes, NOT as mkosi.finalize: mkosi v26 runs finalize
# before the UKI is staged, so the rename silently skips. Idempotent.
# Usage: IMAGE_VERSION=<calver> [OUTPUTDIR=build] scripts/stage-artifacts.sh

set -euo pipefail

VER="${IMAGE_VERSION:-}"
OUT="${OUTPUTDIR:-build}"
# mkosi exports ARCHITECTURE (%a); fall back to uname for manual runs.
ARCH="${ARCHITECTURE:-$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')}"

if [ -z "$VER" ]; then
    echo "stage-artifacts: no IMAGE_VERSION; skipping PartitionUUID rename"
    exit 0
fi

UKI="$OUT/myosi_${VER}_${ARCH}.efi"
if [ ! -f "$UKI" ]; then
    echo "stage-artifacts: no UKI at $UKI; skipping rename"
    exit 0
fi

# Extract the roothash from the UKI's .cmdline section. The
# systemd/mkosi GitHub Action does NOT put ukify on the runner (it
# builds via ToolsTree); the CI workflow installs systemd-ukify explicitly.
if ! command -v ukify >/dev/null; then
    echo "stage-artifacts: ERROR: ukify not on PATH; install systemd-ukify" >&2
    exit 1
fi

# `ukify inspect` dumps binary PE section contents on stdout; grep
# auto-detects NULs and silently returns empty (section order varies
# across ukify versions). `-a` forces text mode, LC_ALL=C keeps the
# regex byte-oriented.
ROOTHASH=$(LC_ALL=C ukify inspect "$UKI" 2>/dev/null \
    | LC_ALL=C grep -a -m1 -oE 'roothash=[a-f0-9]+' \
    | cut -d= -f2 || true)

# No roothash = no verity-protected root. Fail hard so the pipeline
# never ships artifacts sysupdate can't use.
if [ -z "$ROOTHASH" ] || [ ${#ROOTHASH} -ne 64 ]; then
    echo "stage-artifacts: ERROR: could not extract a 64-hex-char roothash from $UKI" >&2
    echo "stage-artifacts:        ukify inspect output: $(ukify inspect "$UKI" 2>&1 | head -20)" >&2
    exit 1
fi

# Render 32 hex chars as a UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
to_uuid() {
    echo "$1" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12})$/\1-\2-\3-\4-\5/'
}

ROOT_UUID=$(to_uuid "${ROOTHASH:0:32}")
VERITY_UUID=$(to_uuid "${ROOTHASH:32:32}")

echo "stage-artifacts: roothash=$ROOTHASH"
echo "stage-artifacts: root_uuid=$ROOT_UUID"
echo "stage-artifacts: verity_uuid=$VERITY_UUID"

# Rename root + verity artifacts; skip existing targets (idempotent)
# and symlinks (mkosi's `build/<image-name>` links).
rename_one() {
    local suffix="$1" uuid="$2" ext="$3"
    # PartitionUUID is inserted AFTER the arch token to match the
    # sysupdate transfers' `@v_%a_@u` ordering.
    local src="$OUT/myosi_${VER}_${ARCH}.${suffix}${ext}"
    local dst="$OUT/myosi_${VER}_${ARCH}_${uuid}.${suffix}${ext}"
    if [ ! -f "$src" ] || [ -L "$src" ]; then return 0; fi
    if [ -e "$dst" ]; then return 0; fi
    mv "$src" "$dst"
    echo "stage-artifacts: renamed $(basename "$src") → $(basename "$dst")"
}

for ext in .raw.zst .raw .raw.xz; do
    rename_one root   "$ROOT_UUID"   "$ext"
    rename_one verity "$VERITY_UUID" "$ext"
done
