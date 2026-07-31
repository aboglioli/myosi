# myosi justfile — dev-host build/install/test only. Operator commands
# ship as just modules under /usr/share/myosi/just/ on the deployed
# host, dispatched via the `myosi` wrapper (`myosi --list`).

# Show available recipes
default:
    @just --list

# Generate local signing keys + OVMF varstore (one-time)
keys-generate:
    ./scripts/generate-keys.sh

# mkosi v26 has no --image flag: with mkosi.images/ present it builds
# main + all configured sub-images. No `build-sub` on purpose —
# standalone `mkosi -C` sub-image builds don't inherit top-level
# [Validation]/BuildSources=/Dependencies=; incremental mode makes
# per-sub-image iteration cheap.

# Build base + sub-images (dev = incremental `-fi`, full = clean `-ff`; CI uses full).
build mode="dev":
    #!/usr/bin/env bash
    set -euo pipefail
    # BuildSources=build:build_share is parse-time-resolved; on a fresh
    # worktree mkosi bombs before it creates build/ itself.
    mkdir -p build
    # Stage the LUKS bootstrap key for repart Encrypt=key-file (never
    # checked in; see scripts/generate-bootstrap-key.sh).
    ./scripts/generate-bootstrap-key.sh
    # Stamp the myosi commit for /usr/share/myosi/version. Keep in sync
    # with .github/workflows/build.yml, which reimplements this recipe.
    export GIT_COMMIT="$(git rev-parse --short HEAD)"
    case "{{mode}}" in
        dev)  sudo --preserve-env mkosi -fi build ;;
        full) sudo --preserve-env mkosi -ff build ;;
        *)    echo "ERROR: unknown build mode '{{mode}}' (expected: dev|full)" >&2; exit 1 ;;
    esac
    # Rename root/verity artifacts to embed roothash-derived GPT
    # PartitionUUIDs (sysupdate @u capture). Must run after mkosi build
    # — mkosi v26 runs finalize hooks before the UKI is staged.
    VER=$(bash mkosi.version)
    ARCH=$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')
    sudo IMAGE_VERSION="$VER" ARCHITECTURE="$ARCH" OUTPUTDIR=build scripts/stage-artifacts.sh

# Boot in qemu/OVMF — full UEFI + UKI + dm-verity + LUKS chain. SSH in
# via `mkosi ssh` from another terminal (one-time setup: `mkosi genkey`).
# Optional sysexts are injected from build/ without a rebuild:
#   just vm virt desktop

# Boot the built image in a VM (optionally with sysexts injected).
vm +sysexts="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{sysexts}}" ]; then
        exec mkosi -f vm --ssh=runtime
    fi
    # Parse version from the built UKI — running mkosi.version here could
    # mint a NEW counter value and miss the artifacts actually in build/.
    ARCH=$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')
    UKI=$(find build -maxdepth 1 -name "myosi_*_${ARCH}.efi" | sort -V | tail -1)
    [ -n "$UKI" ] || { echo "ERROR: no built UKI in build/ — run 'just build' first" >&2; exit 1; }
    VERSION=$(basename "$UKI" | sed -E "s/^myosi_(.+)_${ARCH}\.efi$/\1/")
    EXTDIR=$(mktemp -d -t myosi-vm-ext-XXXXXX)
    trap 'rm -rf "$EXTDIR"' EXIT
    for sx in {{sysexts}}; do
        f="build/${sx}_${VERSION}_${ARCH}.raw"
        [ -f "$f" ] && cp "$f" "$EXTDIR/" || echo "WARNING: sysext $sx not found at $f" >&2
    done
    mkosi -f vm --ssh=runtime --runtime-tree="$EXTDIR:/var/lib/extensions"

# Boot the base image in systemd-nspawn (userspace only — no UKI/dm-verity/LUKS)
nspawn:
    mkosi boot

# Write the disk image to a block device — same script that ships at
# /usr/libexec/myosi/install (single source of truth), so any myosi host
# can install onward and this recipe works from any dev host. Usage:
#   just install /dev/sdX                       # USB from repo build
#   just install /dev/nvme0n1 [/dev/sdb]        # internal disk [clone from a device]
#   just install /dev/sda build/myosi_VER.raw   # explicit file
#   just install /dev/sdb latest                # stream from GitHub release

# Install the disk image to a block device (USB or internal disk).
install device source="":
    #!/usr/bin/env bash
    set -euo pipefail
    # cd to the user's shell CWD — just runs recipes from the justfile
    # dir, which would silently break relative source paths.
    cd "{{ invocation_directory() }}"
    sudo --preserve-env=MYOSI_GH_TOKEN,GH_TOKEN,GITHUB_TOKEN,MYOSI_REPO \
        "{{ justfile_directory() }}/mkosi.extra/usr/libexec/myosi/install" \
        {{device}} {{source}}

# Clean all build artifacts
clean:
    mkosi clean
