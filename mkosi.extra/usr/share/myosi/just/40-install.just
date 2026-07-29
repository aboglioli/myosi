#!/usr/bin/env just --justfile

# Installation and deployment operations — destructive, run rarely.
# Thin wrapper over /usr/libexec/myosi/install (same script the dev-host
# `just install` recipe uses): single source of truth.

# Install myosi to a target device. Destructive — wipes the device.
# Source: omitted (auto-pick build/ → staging → live disk → latest release),
# /dev/... (dd-clone), image file (.raw[.xz|.zst]), YYYY.MM.DD.NN, or latest.
# --reset-identity wipes the data-luks header → fresh identity on next boot.
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
    # cd to the caller's CWD so relative source paths resolve from where the
    # operator is, not the wrapper's transient justfile dir.
    cd "{{ invocation_directory() }}"
    # Pre-extract the gh token: sudo strips $HOME, so root can't read the
    # calling user's gh auth store.
    if [ -z "${GH_TOKEN:-}" ] && [ -z "${MYOSI_GH_TOKEN:-}" ] \
            && [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null; then
        token=$(gh auth token 2>/dev/null || true)
        [ -n "$token" ] && export GH_TOKEN="$token"
    fi
    sudo --preserve-env=MYOSI_GH_TOKEN,GH_TOKEN,GITHUB_TOKEN,MYOSI_REPO \
        "$script" {{target}} {{args}}
