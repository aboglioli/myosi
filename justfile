# myosi justfile — dev-host build/test orchestration.
#
# Operator commands ship as just modules under /usr/share/myosi/just/ on
# the deployed host and are dispatched through the `myosi` wrapper, which
# scans that directory each invocation. Sysexts can drop their own
# NN-<name>.just module into the same dir and add commands at merge
# time. Available commands (base modules):
#
#   sudo myosi extension-enable   <name> [version]
#   sudo myosi extension-disable  <name>
#   sudo myosi update             run|fetch|apply|status|vacuum [version]
#   sudo myosi enroll-tpm
#   sudo myosi add-data-disk      <device> [label]
#   myosi  --list                 # show all commands
#
# This file covers only dev-host build/test orchestration.

# Show available recipes
default:
    @just --list

# Generate local signing keys + OVMF varstore (one-time)
keys-generate:
    ./scripts/generate-keys.sh

# Build everything: base + every sub-image in mkosi.images/
# mkosi v26: no --image flag. With mkosi.images/ present, mkosi builds main + all subimages
# automatically.
#
# Modes:
#   just build         → incremental dev rebuild (default) — `mkosi -fi build`.
#                        Reuses cached sub-image final trees in mkosi.builddir/;
#                        only postinst-touched sub-images actually re-run. Use
#                        when iterating on one sub-image without bumping
#                        mkosi.shared/ or cross-cutting config.
#   just build full    → clean rebuild — `mkosi -ff build`. CI and release
#                        artifacts always use this so output isn't
#                        contaminated by stale cache state.
#
# The shipped .raw.zst is the minimal 4-partition layout (ESP + root-A +
# verity-A + verity-sig-A, ~700 MB compressed). First-boot systemd-repart
# inside the initrd reads /usr/lib/repart.d/ (the runtime 8-partition layout
# from mkosi.repart.runtime/, baked in via mkosi.conf ExtraTrees=) and creates
# root-B + verity-B + verity-sig-B + data-luks, growing data-luks to fill
# the target disk. Same .raw works as USB live + installed root (Lennart
# Poettering's "Fitting Everything Together" pattern).
#
# The SELinux file-contexts hand-off to mkfs.erofs is configured in
# mkosi.shared/sysext.conf via Environment=SYSTEMD_REPART_MKFS_OPTIONS_EROFS=...
# which mkosi propagates through config.finalize_environment() into the
# env passed to systemd-repart subprocesses. No shell export needed here.

# Build base + all sub-images (mode: dev=incremental, full=clean).
build mode="dev":
    #!/usr/bin/env bash
    set -euo pipefail
    # mkosi.conf declares `BuildSources=build:build_share` which is
    # parse-time-resolved. On a fresh worktree `build/` doesn't exist
    # yet (it gets created by mkosi as OutputDirectory) so the parse
    # bombs before mkosi creates the dir. Pre-mkdir is a one-liner.
    mkdir -p build
    # Bootstrap LUKS key for repart Encrypt=key-file. Re-generated fresh
    # per build so the key embedded in each UKI is unique; the file is
    # never checked in (see .gitignore). See scripts/generate-bootstrap-key.sh
    # for the operator post-install wipe runbook.
    ./scripts/generate-bootstrap-key.sh
    # Stamp the real commit so /usr/share/myosi/version doesn't read
    # GIT_COMMIT=unknown. Keep in sync with .github/workflows/myosi.yml,
    # which reimplements this recipe step by step.
    export GIT_COMMIT="$(git -C .. rev-parse --short HEAD)"
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
    # Stage split artifacts: rename root + verity .raw.zst to embed
    # roothash-derived GPT PartitionUUIDs (Discoverable Partitions
    # Spec). Sysupdate captures via @u at apply time. Runs after
    # mkosi build completes (NOT as a mkosi.finalize hook — mkosi v26
    # runs finalize before the UKI is staged at OUTPUTDIR).
    VER=$(bash mkosi.version)
    # mkosi.conf sets Output=%i_%v_%a so stage-artifacts has to know
    # the arch to find the right basename. Pass it explicitly — local
    # builds default to the host's `uname -m`.
    ARCH=$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')
    sudo IMAGE_VERSION="$VER" ARCHITECTURE="$ARCH" OUTPUTDIR=build scripts/stage-artifacts.sh

# NOTE: there is intentionally no `build-sub` recipe. mkosi -C standalone
# sub-image builds don't inherit top-level [Validation], BuildSources= or
# Dependencies= (verified — fails with three orthogonal errors). Per-sub-image
# iteration goes through `just build` (incremental) which only re-runs
# postinst-touched sub-images — cheap enough that a standalone path isn't
# needed. See the "Design notes" section in README.md ("Why no standalone sub-image builds") for the
# full rationale.

# Boot in qemu with OVMF firmware — full UEFI + UKI + dm-verity + LUKS chain.
# Interactive console (tty1). Use inside tmux if headless.
# -f: skip "not built yet" check (needed when version bumped by CI or other agents)

# Boot in qemu/OVMF — full UEFI + UKI + dm-verity + LUKS chain.
qemu:
    mkosi -f vm

# Headless qemu boot with SSH access — recommended for remote/SSH sessions.
# One-time setup: mkosi genkey (generates keys for 'mkosi ssh')
# Then: just qemu-ssh (in tmux) → mkosi ssh (from another terminal)

# Headless qemu boot with SSH — use for remote sessions.
qemu-ssh:
    mkosi -f vm --ssh=runtime

# QEMU boot with sysexts injected at boot (no rebuild).
# Copies named sysext .raw files from build/ to a tmp dir, bind-mounts via --runtime-tree.
# Usage: just qemu-ext virt desktop containers
# Pass one or more sysext names; omit arguments to boot without injected sysexts.

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

# Write the myosi disk image to a block device (USB stick OR internal disk).
# Same operation either way — the image is a full GPT disk.
#
# The install script is the same one that ships in the deployed image at
# /usr/libexec/myosi/install (single source of truth), so a booted USB
# can call `myosi install …` and the dev box can call `just install …`
# without two copies drifting apart.
#
# Release fetch path tries gh first, then REST API via curl. Public
# releases need no auth; for a private fork pass a token via
# MYOSI_GH_TOKEN / GH_TOKEN / GITHUB_TOKEN. Split
# releases (.raw.zst.part00, .part01, ...) are reassembled on the fly.
#
# Usage:
#   just install /dev/sdX                       # write USB from repo build
#   just install /dev/nvme0n1                   # internal disk, auto-pick
#   just install /dev/nvme0n1 /dev/sdb          # clone live USB onto NVMe
#   just install /dev/sda build/myosi_VER.raw   # explicit file
#   just install /dev/sdb latest                # stream from GitHub release

# Write the disk image to a block device (USB or internal disk).
install device source="":
    #!/usr/bin/env bash
    set -euo pipefail
    # cd to the user's shell CWD so a bare-filename source like
    # `myosi_VER.raw` resolves the way the user typed it. just runs
    # recipes from the justfile dir by default, which otherwise
    # silently turns `build/myosi.raw` (from build/) into
    # `myosi/build/myosi.raw` not found.
    cd "{{ invocation_directory() }}"
    # Pre-extract gh auth token (needed only for private forks / rate
    # limits). sudo strips $HOME, so root cannot read
    # gh's auth store. Setting GH_TOKEN in the user shell and
    # --preserve-env'ing it gets the sudo'd gh+curl path working.
    if [ -z "${GH_TOKEN:-}" ] && [ -z "${MYOSI_GH_TOKEN:-}" ] \
            && [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null; then
        token=$(gh auth token 2>/dev/null || true)
        [ -n "$token" ] && export GH_TOKEN="$token"
    fi
    sudo --preserve-env=MYOSI_GH_TOKEN,GH_TOKEN,GITHUB_TOKEN,MYOSI_REPO \
        "{{ justfile_directory() }}/mkosi.extra/usr/libexec/myosi/install" \
        {{device}} {{source}}
