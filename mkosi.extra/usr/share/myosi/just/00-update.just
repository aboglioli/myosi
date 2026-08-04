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
update version="" refresh="":
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    sysupdate_env

    raw_version="{{version}}"
    raw_refresh="{{refresh}}"
    REFRESH=false
    case "$raw_version:$raw_refresh" in
        --refresh:)
            raw_version=""
            REFRESH=true
            ;;
        --refresh:*)
            raw_version="$raw_refresh"
            REFRESH=true
            ;;
        *:--refresh)
            REFRESH=true
            ;;
        *:)
            ;;
        *)
            echo "ERROR: usage: myosi update [--refresh] [VERSION]" >&2
            exit 2
            ;;
    esac

    command -v "$SYSUPDATE" >/dev/null || { echo "ERROR: $SYSUPDATE is required" >&2; exit 4; }

    # The url-file source exposes only the latest release
    # (releases/latest/download); an explicit VERSION works only when it
    # IS the latest. Older-version installs go through the sd-boot menu
    # (previous slot) or `myosi extension-enable NAME VERSION`.
    cmd=("$SYSUPDATE" update)
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
