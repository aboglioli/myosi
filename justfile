# myosi justfile — dev-host build/test orchestration only. Operator
# commands ship as just modules under /usr/share/myosi/just/ on the
# deployed host, dispatched via the `myosi` wrapper (`myosi --list`);
# sysexts can add NN-<name>.just modules to the same dir.

# Show available recipes
default:
    @just --list

# Generate local signing keys + OVMF varstore (one-time)
keys-generate:
    ./scripts/generate-keys.sh

# mkosi v26 has no --image flag: with mkosi.images/ present it builds
# main + all sub-images automatically.
#   just build       → incremental (`mkosi -fi`); only postinst-touched
#                      sub-images re-run.
#   just build full  → clean rebuild (`mkosi -ff`); CI/release always use
#                      this to avoid stale-cache contamination.

# Build base + all sub-images (mode: dev=incremental, full=clean).
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
        dev)
            echo "Building incrementally"
            sudo --preserve-env mkosi -fi build
            ;;
        full)
            echo "Full clean rebuild"
            sudo --preserve-env mkosi -ff build
            ;;
        *)
            echo "ERROR: unknown build mode '{{mode}}' (expected: dev|full)" >&2
            exit 1
            ;;
    esac
    # Rename root/verity artifacts to embed roothash-derived GPT
    # PartitionUUIDs (sysupdate @u capture). Must run after mkosi build
    # — mkosi v26 runs finalize hooks before the UKI is staged.
    VER=$(bash mkosi.version)
    # Output=%i_%v_%a: pass the arch so stage-artifacts finds the basename.
    ARCH=$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')
    sudo IMAGE_VERSION="$VER" ARCHITECTURE="$ARCH" OUTPUTDIR=build scripts/stage-artifacts.sh

# NOTE: intentionally no `build-sub` recipe — standalone `mkosi -C`
# sub-image builds don't inherit top-level [Validation], BuildSources=
# or Dependencies=. Iterate via `just build` (incremental) instead.

# -f skips the "not built yet" check (version may be bumped by CI).

# Boot in qemu/OVMF — full UEFI + UKI + dm-verity + LUKS chain.
qemu:
    mkosi -f vm

# One-time setup: mkosi genkey; then `mkosi ssh` from another terminal.

# Headless qemu boot with SSH — use for remote sessions.
qemu-ssh:
    mkosi -f vm --ssh=runtime

# Usage: just qemu-ext virt desktop containers

# Qemu boot with named sysexts injected at boot (no rebuild).
qemu-ext +sysexts="":
    #!/usr/bin/env bash
    set -euo pipefail
    VERSION=$(ls build/ | grep -oP '\d{4}\.\d{2}\.\d{2}\.\d{2}' | head -1)
    ARCH=$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')
    EXTDIR=/tmp/myosi-extensions-$$
    mkdir -p "$EXTDIR"
    for sx in {{sysexts}}; do
        f=$(ls "build/${sx}_${VERSION}_${ARCH}.raw" 2>/dev/null | head -1)
        [ -n "$f" ] && cp "$f" "$EXTDIR/" || echo "WARNING: sysext $sx not found in build/" >&2
    done
    trap "rm -rf $EXTDIR" EXIT
    mkosi -f vm --ssh=runtime \
        --runtime-tree="$EXTDIR:/var/lib/extensions"

# Boot the base image in systemd-nspawn (does NOT exercise UKI/dm-verity/LUKS)
nspawn:
    mkosi boot

# Clean all build artifacts (mkosi v26 verb)
clean:
    mkosi clean

# Runs the same script that ships in the image at
# /usr/libexec/myosi/install (single source of truth). Release fetch
# tries gh then curl; private forks need MYOSI_GH_TOKEN / GH_TOKEN /
# GITHUB_TOKEN. Split releases (.part00, ...) reassemble on the fly.
# Usage:
#   just install /dev/sdX                       # write USB from repo build
#   just install /dev/nvme0n1 [/dev/sdb]        # internal disk [clone from USB]
#   just install /dev/sda build/myosi_VER.raw   # explicit file
#   just install /dev/sdb latest                # stream from GitHub release

# Write the disk image to a block device (USB or internal disk).
install device source="":
    #!/usr/bin/env bash
    set -euo pipefail
    # cd to the user's shell CWD — just runs recipes from the justfile
    # dir, which would silently break relative source paths.
    cd "{{ invocation_directory() }}"
    # Pre-extract the gh auth token: sudo strips $HOME so root can't
    # read gh's auth store; --preserve-env carries it through.
    if [ -z "${GH_TOKEN:-}" ] && [ -z "${MYOSI_GH_TOKEN:-}" ] \
            && [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null; then
        token=$(gh auth token 2>/dev/null || true)
        [ -n "$token" ] && export GH_TOKEN="$token"
    fi
    sudo --preserve-env=MYOSI_GH_TOKEN,GH_TOKEN,GITHUB_TOKEN,MYOSI_REPO \
        "{{ justfile_directory() }}/mkosi.extra/usr/libexec/myosi/install" \
        {{device}} {{source}}
