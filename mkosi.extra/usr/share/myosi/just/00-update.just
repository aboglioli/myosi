# Update base image + enabled sysexts atomically via systemd-sysupdate.
# The repo is public: transfers fetch straight from the GitHub release
# (url-file source + SHA256SUMS manifest) — no gh auth, no local cache
# staging. Base root/verity/UKI and feature-enabled sysexts live in ONE
# sysupdate.d dir sharing @v, so a version is only ever offered when
# every enabled transfer has assets for it. Calls the systemd-sysupdate
# binary directly (the `sysupdate` symlink), not updatectl:
# systemd-sysupdated's F44 SELinux sandbox silently denies loop devices
# and dosfs_t /efi writes (details in lib.sh sysupdate_env).

# ------- update ----------------------------------------------------

[group('update')]
update *args:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    sysupdate_env

    REFRESH=false
    TAG=""
    raw_version=""
    set -- {{args}}
    while [ $# -gt 0 ]; do
        case "$1" in
            --refresh)
                REFRESH=true
                ;;
            --tag)
                [ $# -ge 2 ] || { echo "ERROR: --tag needs a release tag" >&2; exit 2; }
                TAG="$2"
                shift
                ;;
            -*)
                echo "ERROR: usage: myosi update [--refresh] [--tag TAG] [VERSION]" >&2
                exit 2
                ;;
            *)
                [ -z "$raw_version" ] || { echo "ERROR: usage: myosi update [--refresh] [--tag TAG] [VERSION]" >&2; exit 2; }
                raw_version="$1"
                ;;
        esac
        shift
    done

    command -v "$SYSUPDATE" >/dev/null || { echo "ERROR: $SYSUPDATE is required" >&2; exit 4; }

    LUKS_DEV=/dev/disk/by-partlabel/data-luks
    if [ -e "$LUKS_DEV" ] && \
       cryptsetup luksOpen --test-passphrase \
           --key-file /usr/share/myosi/keys/data.key "$LUKS_DEV" \
           >/dev/null 2>&1; then
        echo "WARNING: $LUKS_DEV still unlocks with the public bootstrap key." >&2
        echo "         Run 'myosi security-check' and finalize the host (README 3d)." >&2
    fi

    # The url-file source exposes only the latest release
    # (releases/latest/download); an explicit VERSION works only when it
    # IS the latest. Older-version installs go through the sd-boot menu
    # (previous slot) or `myosi extension-enable NAME VERSION`.
    cmd=("$SYSUPDATE" update)
    if [ -n "$TAG" ]; then
        [[ "$TAG" =~ ^[0-9]{4}(\.[0-9]{2}){2}(\.[0-9]{2})?$ ]] || {
            echo "ERROR: --tag expects a release tag like 2026.11.15 or 2026.11.15.01" >&2
            exit 2
        }
        DEFINITIONS=$(mktemp -d)
        trap 'rm -r -- "$DEFINITIONS"' EXIT
        cp -r "$SU_DIR"/. "$DEFINITIONS"/
        [ ! -d /etc/sysupdate.d ] || cp -r /etc/sysupdate.d/. "$DEFINITIONS"/
        sed -i "s#releases/latest/download#releases/download/$TAG#" "$DEFINITIONS"/*.transfer
        cmd+=("--definitions=$DEFINITIONS")
        echo "Installing release $TAG (a pre-release stays out of the Latest channel)."
    fi
    [ -n "$raw_version" ] && [ "$raw_version" != latest ] && cmd+=("$raw_version")
    "${cmd[@]}"

    if [ "$REFRESH" = "true" ]; then
        refresh_sysext
        echo "Refreshed active sysext overlay. Restart affected services manually."
    fi

    echo "Staged updates. Reboot to activate the new root, UKI and sysexts together."
    [ "$REFRESH" = "true" ] || \
        echo "The running system is unchanged (sysext-select picks the booted image's sysext versions)."

# ------- status ----------------------------------------------------

[group('update')]
status:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    sysupdate_env

    if command -v "$SYSUPDATE" >/dev/null; then
        echo "== host + extensions =="
        "$SYSUPDATE" list --no-pager 2>/dev/null | sed 's/^/  /' || true
        echo
        echo "== features =="
        "$SYSUPDATE" features --no-pager 2>/dev/null | sed 's/^/  /' || true
        echo
    fi

    echo "== sysext store (/var/lib/myosi/extensions) =="
    find /var/lib/myosi/extensions -maxdepth 1 -type f -name '*.raw' -printf '  %f\n' 2>/dev/null | sort || true
    echo
    echo "== selected for merge (/var/lib/extensions) =="
    find /var/lib/extensions -maxdepth 1 -name '*.raw' -printf '  %f\n' 2>/dev/null | sort || true
    echo
    echo "== active sysexts =="
    systemd-sysext list --no-pager 2>/dev/null || true

# ------- vacuum ----------------------------------------------------

[group('update')]
vacuum:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    sysupdate_env

    command -v "$SYSUPDATE" >/dev/null || { echo "ERROR: $SYSUPDATE is required" >&2; exit 4; }
    "$SYSUPDATE" vacuum 2>/dev/null || true
