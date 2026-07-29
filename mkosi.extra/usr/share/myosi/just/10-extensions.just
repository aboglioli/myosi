# Enable, disable, and list sysext features.

[group('extensions')]
extension-enable name version="":
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    if [ -z "{{name}}" ]; then echo "Usage: myosi extension-enable <name> [version]" >&2; exit 2; fi
    validate_name "{{name}}" sysext

    if [ ! -f "/usr/lib/sysupdate.extensions.d/{{name}}.feature" ]; then
        echo "ERROR: unknown sysext feature: {{name}}" >&2
        echo "Available features:" >&2
        find /usr/lib/sysupdate.extensions.d -maxdepth 1 -name '*.feature' -printf '  %f\n' 2>/dev/null | sed 's/\.feature$//' >&2
        exit 4
    fi

    REPO="${MYOSI_REPO:-user/myosi}"
    sysupdate_env

    current_image_version() {
        for f in /usr/lib/os-release /etc/os-release; do
            [ -f "$f" ] || continue
            awk -F= '$1=="IMAGE_VERSION"{v=$2;gsub(/^"|"$/,"",v);print v;exit}' "$f"
        done | head -1
    }

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

    install -d -m 0755 "$CACHE" /var/lib/extensions
    install -m 0644 "$TMPDIR/$ASSET" "$CACHE/$ASSET"
    install -m 0644 "$TMPDIR/$ASSET" "/var/lib/extensions/$ASSET"

    mapfile -t old_versions < <(find /var/lib/extensions -maxdepth 1 -type f -name "{{name}}_*.raw" -printf '%p\n' 2>/dev/null | sort -V)
    if [ "${#old_versions[@]}" -gt 2 ]; then
        for old in "${old_versions[@]:0:${#old_versions[@]}-2}"; do
            rm -f "$old"
        done
    fi

    feature_enable "{{name}}" sysupdate.extensions.d
    refresh_sysext

    if ! keyctl list %:.platform 2>/dev/null | grep -qE 'myosi DEV Image' \
       && ! keyctl list %:.machine  2>/dev/null | grep -qE 'myosi DEV Image'; then
        echo >&2
        echo "NOTE: image.crt isn't loaded into .platform/.machine yet" >&2
        echo "      sysext merged with integrity-only validation." >&2
        echo "      See README § Step 3c for the full procedure." >&2
    fi

    [ -n "{{version}}" ] && echo "Enabled sysext '{{name}}' at version {{version}}." \
                         || echo "Enabled sysext '{{name}}' at the latest release."

[group('extensions')]
extension-disable name:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    if [ -z "{{name}}" ]; then echo "Usage: myosi extension-disable <name>" >&2; exit 2; fi
    validate_name "{{name}}" sysext

    feature_disable "{{name}}" sysupdate.extensions.d
    rm -f /var/lib/extensions/"{{name}}"_*.raw "/var/lib/extensions/{{name}}.raw"
    rm -f /var/lib/sysupdate/"{{name}}"_*.raw

    sysupdate_env
    if command -v "$SYSUPDATE" >/dev/null; then
        "$SYSUPDATE" --component=extensions vacuum 2>/dev/null || true
    fi

    refresh_sysext
    echo "Disabled sysext '{{name}}'. Reboot to guarantee it is fully unmerged."

[group('extensions')]
extension-list:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    sysupdate_env

    echo "== available features =="
    if [ -d "$EXT_DIR" ]; then
        find "$EXT_DIR" -maxdepth 1 -name '*.feature' -printf '  %f\n' 2>/dev/null \
            | sed 's/\.feature$//' | sort
    fi
    echo
    if command -v "$SYSUPDATE" >/dev/null; then
        echo "== extensions update sets =="
        "$SYSUPDATE" --component=extensions list --no-pager 2>/dev/null | sed 's/^/  /' || true
        echo
    fi
    echo "== sysexts on disk =="
    echo "-- /usr/lib/extensions/  (verity-baked) --"
    find /usr/lib/extensions -maxdepth 1 -type f -name '*.raw' -printf '  %f\n' 2>/dev/null | sort
    echo "-- /var/lib/extensions/  (operator-installed) --"
    find /var/lib/extensions -maxdepth 1 -type f -name '*.raw' -printf '  %f\n' 2>/dev/null | sort
    echo
    echo "== active sysexts (merged into /usr) =="
    systemd-sysext list --no-pager 2>/dev/null || true
