#!/usr/bin/env just --justfile

# Installation and deployment operations.
#
# These operations are destructive and typically performed once during
# initial setup, when cloning an existing installation to a new device,
# or when streaming a fresh release onto a primary disk.
#
# The install script ships at /usr/libexec/myosi/install (same script
# used by the dev-host `just install` recipe). Single source of truth —
# whatever the dev box does is what a booted USB does.

# Install myosi to a target device. Destructive — wipes the device.
#
# Source resolution:
#   omitted             auto-pick: build/ → /run/myosi-installer → live disk
#                       → fallback to GitHub release `latest`.
#   /dev/...            block device, dd-clone (e.g. clone live USB → NVMe).
#   path/to/image.raw   file, decompressed (.xz/.zst) and dd'd.
#   YYYY.MM.DD.NN       fetch that GitHub release, stream zstd → dd.
#   latest              resolve current latest release, stream zstd → dd.
#
# --reset-identity wipes the data-luks header on the freshly written
# disk so the next boot runs fresh luksFormat, prompts for a new
# passphrase, and regenerates machine-id + ssh host keys.
#
# Examples:
#   sudo myosi install /dev/sdb                                # USB stick
#   sudo myosi install /dev/nvme0n1 /dev/sdb                   # clone live USB
#   sudo myosi install /dev/nvme0n1 latest --reset-identity    # fresh install
#   sudo myosi install /dev/nvme0n1 2026.06.05.03              # pin version
install target *args:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{target}}" ]; then
        echo "Usage: myosi install <target-device> [source] [--reset-identity]" >&2
        exit 1
    fi
    script=/usr/libexec/myosi/install
    if [ ! -x "$script" ]; then
        echo "ERROR: install script missing at $script" >&2
        exit 1
    fi
    # cd to the caller's shell CWD so a relative source path resolves
    # against where the operator actually is, not /run/myosi (the dir
    # the wrapper's transient justfile lives in).
    cd "{{ invocation_directory() }}"
    # Pre-extract gh token in the user's environment so the sudo'd
    # install script can hit the private repo. sudo strips $HOME, so
    # root can't read the calling user's gh auth store.
    if [ -z "${GH_TOKEN:-}" ] && [ -z "${MYOSI_GH_TOKEN:-}" ] \
            && [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null; then
        token=$(gh auth token 2>/dev/null || true)
        [ -n "$token" ] && export GH_TOKEN="$token"
    fi
    sudo --preserve-env=MYOSI_GH_TOKEN,GH_TOKEN,GITHUB_TOKEN,MYOSI_REPO \
        "$script" {{target}} {{args}}
