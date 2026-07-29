#!/usr/bin/env bash
# Renames split-artifact filenames to embed the dm-verity-derived GPT
# PartitionUUIDs per the Discoverable Partitions Spec.
#
# Usage:
#   IMAGE_VERSION=<calver> [OUTPUTDIR=build] ci/lib/stage-artifacts.sh
#
# This script MUST run AFTER `mkosi build` has fully completed and
# staged all split artifacts (including the UKI) under OUTPUTDIR.
# We do not invoke it as `mkosi.finalize` because mkosi v26 runs
# finalize hooks BEFORE the split artifacts are populated — the UKI
# isn't there yet, so the rename silently skips. Verified failure
# mode on the 2026.06.07.02 release: finalize logged
# "no UKI at /work/out/myosi_2026.06.07.02.efi; skipping rename"
# even though the UKI ended up in build/ after mkosi finished.
#
# Both `just build` and the GitHub Actions workflow invoke this
# script explicitly after `mkosi build`, so the timing is
# deterministic. Single source of truth, works in both contexts.
#
# Background:
#   systemd-sysupdate writes new partition content during A/B updates
#   but leaves the destination partition's GPT PartitionUUID
#   unchanged unless the source filename embeds the new UUID via the
#   `@u` wildcard. Without the rename, every sysupdate-driven boot
#   into the new slot hangs in initrd waiting for
#   /dev/disk/by-partuuid/<roothash-derived-uuid> which never appears.
#   Verified failure mode on the 2026.06.06.04 release.
#
# The .transfer files (mkosi.extra/usr/lib/sysupdate.d/10-root.transfer,
# 11-verity.transfer) carry MatchPattern=myosi_@v_%a_@u.<kind>.raw.zst.
# This script renames root and verity .raw.zst artifacts so the @u
# capture finds the expected GPT PartitionUUID while %a keeps the match
# pinned to the host architecture.
#
# Discoverable Partitions Spec mapping (UAPI Group):
#   root partition PartitionUUID   = first 16 bytes of dm-verity root hash
#   verity partition PartitionUUID = last 16 bytes of dm-verity root hash
# Both halves rendered as standard 8-4-4-4-12 hex UUIDs.
#
# Idempotent: re-running on the same OUTPUTDIR is a no-op once the
# renamed files exist.

set -euo pipefail

VER="${IMAGE_VERSION:-}"
OUT="${OUTPUTDIR:-build}"
# mkosi exports ARCHITECTURE matching the %a specifier. Fall back to
# uname normalization so a manual run outside mkosi still works.
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

# Extract the roothash from the UKI's .cmdline section. systemd-ukify
# is required on the build host. mkosi itself uses ukify to assemble
# the UKI, so it is typically present alongside mkosi — but the
# `systemd/mkosi@main` GitHub Action does NOT pull it onto the runner
# (mkosi builds UKIs via its ToolsTree). The CI workflow installs
# systemd-ukify explicitly; local builds get it via mkosi's own
# dependency chain on Fedora.
if ! command -v ukify >/dev/null; then
    echo "stage-artifacts: ERROR: ukify not on PATH; install systemd-ukify" >&2
    exit 1
fi

# `ukify inspect` dumps a mix of textual headers and the verbatim
# binary contents of PE sections (.linux, .initrd, ...) on stdout.
# GNU grep auto-detects the NUL bytes and, with -o, prints
# "binary file matches" on stderr instead of the matching text,
# leaving stdout empty. Local builds happened to find the roothash
# before the first NUL (ukify 259.5); CI runs on ukify 259.6 which
# orders the dump differently and the extraction silently returned
# empty — verified failure mode on the 2026.06.07.04 GitHub Action
# release (40 min build, then "stage-artifacts: ERROR: could not
# extract a 64-hex-char roothash"). `-a` (--binary-files=text) forces
# grep to treat input as text and print matches regardless of NUL
# content. `LC_ALL=C` keeps the regex byte-oriented.
ROOTHASH=$(LC_ALL=C ukify inspect "$UKI" 2>/dev/null \
    | LC_ALL=C grep -a -m1 -oE 'roothash=[a-f0-9]+' \
    | cut -d= -f2 || true)

# A UKI without a roothash means the build did not include
# verity-protected /usr. Fail hard so the build pipeline doesn't ship
# artifacts that sysupdate cannot use. Verified failure mode in the
# 2026.06.06.04 release: silently-missing PartitionUUIDs caused
# initrd-timeout in production.
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

# Rename root + verity per-partition artifacts. Idempotent: skip if the
# renamed file already exists (handles re-runs on the same build dir).
# Skip symlinks because mkosi creates `build/<image-name>` symlinks
# alongside the raw artifacts and we don't want to clobber them.
rename_one() {
    local suffix="$1" uuid="$2" ext="$3"
    # mkosi names split artifacts <ImageId>_<Version>_<Arch>.<suffix>.raw[.zst]
    # (Output=%i_%v_%a). The PartitionUUID slot is inserted AFTER the
    # arch token so sysupdate transfers can keep `@v_%a_@u` ordering
    # in lockstep with the build.
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
