# Enable, disable, and list sysext features. Features + transfers live in
# /usr/lib/sysupdate.d (same dir as the base image transfers — shared @v
# generation); raws land in the versioned store /var/lib/myosi/extensions
# and sysext-select links exactly one version into /var/lib/extensions.

[group('extensions')]
extension-enable name version="":
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    if [ -z "{{name}}" ]; then echo "Usage: myosi extension-enable <name> [version]" >&2; exit 2; fi
    validate_name "{{name}}" sysext

    sysupdate_env
    if [ ! -f "$SU_DIR/{{name}}.feature" ]; then
        echo "ERROR: unknown sysext feature: {{name}}" >&2
        echo "Available features:" >&2
        find "$SU_DIR" -maxdepth 1 -name '*.feature' -printf '  %f\n' 2>/dev/null | sed 's/\.feature$//' >&2
        exit 4
    fi

    REPO=$(myosi_repo)

    # No pipeline into head -1 — it can SIGPIPE the producer under
    # pipefail.
    current_image_version() {
        local f v
        for f in /usr/lib/os-release /etc/os-release; do
            [ -f "$f" ] || continue
            v=$(awk -F= '$1=="IMAGE_VERSION"{gsub(/^"|"$/,"",$2);print $2;exit}' "$f")
            if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
        done
    }

    # Default to the BOOTED image's version, not the latest release:
    # sysext-select only activates the version matching IMAGE_VERSION, and
    # kmod sysexts must match the running kernel. `myosi update` moves the
    # whole generation (base + enabled sysexts) forward together.
    requested_version="{{version}}"
    if [ -z "$requested_version" ]; then
        VERSION=$(current_image_version)
        [ -n "$VERSION" ] || { echo "ERROR: IMAGE_VERSION not found in os-release; pass an explicit version" >&2; exit 5; }
    else
        VERSION=$(resolve_version "$requested_version" "$REPO")
        [ -n "$VERSION" ] || { echo "ERROR: failed to resolve release version" >&2; exit 5; }
    fi

    # Asset name matches the build (Output=%i_%v_%a): <feature>_<VER>_<ARCH>.raw.
    ARCH=$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')
    ASSET="{{name}}_${VERSION}_${ARCH}.raw"
    TMPDIR=$(mktemp -d)
    trap "rm -rf '$TMPDIR'" EXIT
    echo "Downloading $ASSET from $REPO@$VERSION..."
    download_release_asset "$VERSION" "$ASSET" "$TMPDIR/$ASSET" "$REPO"

    install -d -m 0755 "$STORE"
    install -m 0644 "$TMPDIR/$ASSET" "$STORE/$ASSET"

    # Keep two versions in the store (mirrors the transfer's InstancesMax=2).
    mapfile -t old_versions < <(find "$STORE" -maxdepth 1 -type f -name "{{name}}_*.raw" -printf '%p\n' 2>/dev/null | sort -V)
    if [ "${#old_versions[@]}" -gt 2 ]; then
        for old in "${old_versions[@]:0:${#old_versions[@]}-2}"; do
            rm -f "$old"
        done
    fi

    feature_enable "{{name}}" sysupdate.d
    refresh_sysext

    # grep without -q: its early exit can SIGPIPE keyctl under
    # pipefail.
    if ! keyctl list %:.platform 2>/dev/null | grep -E 'myosi DEV Image' >/dev/null \
       && ! keyctl list %:.machine  2>/dev/null | grep -E 'myosi DEV Image' >/dev/null; then
        echo >&2
        echo "NOTE: image.crt isn't loaded into .platform/.machine yet" >&2
        echo "      sysext merged with integrity-only validation." >&2
        echo "      See README § Step 3c for the full procedure." >&2
    fi

    [ -n "{{version}}" ] && echo "Enabled sysext '{{name}}' at version {{version}}." \
                         || echo "Enabled sysext '{{name}}' at the booted image version."

[group('extensions')]
extension-disable name:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    if [ -z "{{name}}" ]; then echo "Usage: myosi extension-disable <name>" >&2; exit 2; fi
    validate_name "{{name}}" sysext

    sysupdate_env
    feature_disable "{{name}}" sysupdate.d
    rm -f "$STORE"/"{{name}}"_*.raw
    # Managed symlink + any legacy direct-drop raws from the pre-store era.
    rm -f /var/lib/extensions/"{{name}}"_*.raw "/var/lib/extensions/{{name}}.raw"

    refresh_sysext
    echo "Disabled sysext '{{name}}'. Reboot to guarantee it is fully unmerged."

[group('extensions')]
extension-list:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    sysupdate_env

    echo "== features (enabled state includes /etc drop-ins) =="
    if command -v "$SYSUPDATE" >/dev/null; then
        "$SYSUPDATE" features --no-pager 2>/dev/null | sed 's/^/  /' || true
    else
        find "$SU_DIR" -maxdepth 1 -name '*.feature' -printf '  %f\n' 2>/dev/null \
            | sed 's/\.feature$//' | sort
    fi
    echo
    echo "== sysexts on disk =="
    echo "-- /usr/share/myosi/extensions/  (verity-baked baselines) --"
    find /usr/share/myosi/extensions -maxdepth 1 -type f -name '*.raw' -printf '  %f\n' 2>/dev/null | sort || true
    echo "-- /var/lib/myosi/extensions/  (sysupdate store, versioned) --"
    find "$STORE" -maxdepth 1 -type f -name '*.raw' -printf '  %f\n' 2>/dev/null | sort || true
    echo "-- /var/lib/extensions/  (selected for merge) --"
    find /var/lib/extensions -maxdepth 1 -name '*.raw' -printf '  %f\n' 2>/dev/null | sort || true
    echo
    echo "== active sysexts (merged into /usr) =="
    systemd-sysext list --no-pager 2>/dev/null || true
