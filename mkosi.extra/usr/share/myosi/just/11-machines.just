# Enable, disable, and list machine DDI features (mybox today).
# Mirrors 10-extensions.just but targets /var/lib/machines/ and skips the
# sysext refresh — activation is operator-driven via machinectl stop/start,
# since a running namespace pins the old image file.

[group('machines')]
machine-enable name version="":
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    if [ -z "{{name}}" ]; then echo "Usage: myosi machine-enable <name> [version]" >&2; exit 2; fi
    validate_name "{{name}}" machine

    if [ ! -f "/usr/lib/sysupdate.machines.d/{{name}}.feature" ]; then
        echo "ERROR: unknown machine feature: {{name}}" >&2
        echo "Available features:" >&2
        find /usr/lib/sysupdate.machines.d -maxdepth 1 -name '*.feature' -printf '  %f\n' 2>/dev/null | sed 's/\.feature$//' >&2
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

    # Asset name matches the build (Output=%i_%v_%a): <name>_<VER>_<ARCH>.raw.
    ARCH=$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')
    ASSET="{{name}}_${VERSION}_${ARCH}.raw"
    TMPDIR=$(mktemp -d)
    trap "rm -rf '$TMPDIR'" EXIT
    echo "Downloading $ASSET from $REPO@$VERSION..."
    download_release_asset "$VERSION" "$ASSET" "$TMPDIR/$ASSET" "$REPO"

    # Versioned filename matches the transfer MatchPattern and keeps prior
    # installs for rollback (InstancesMax=2 enforces retention). Operators
    # symlink {{name}}.raw → desired version when ready to flip.
    install -d -m 0755 "$CACHE" /var/lib/machines
    install -m 0644 "$TMPDIR/$ASSET" "$CACHE/$ASSET"
    install -m 0644 "$TMPDIR/$ASSET" "/var/lib/machines/{{name}}_${VERSION}_${ARCH}.raw"

    mapfile -t old_versions < <(find /var/lib/machines -maxdepth 1 -type f -name "{{name}}_*_${ARCH}.raw" -printf '%p\n' 2>/dev/null | sort -V)
    if [ "${#old_versions[@]}" -gt 2 ]; then
        for old in "${old_versions[@]:0:${#old_versions[@]}-2}"; do
            rm -f "$old"
        done
    fi

    feature_enable "{{name}}" sysupdate.machines.d

    # No auto-restart: a running container holds the old .raw open, and a
    # silent restart would interrupt user sessions. The echo below shows the
    # manual flip; the operator picks the moment.
    echo "Enabled machine '{{name}}' at version ${VERSION} (${ARCH})."
    echo "To activate:"
    echo "  sudo machinectl stop {{name}} 2>/dev/null || true"
    echo "  sudo ln -sfn {{name}}_${VERSION}_${ARCH}.raw /var/lib/machines/{{name}}.raw"
    echo "  sudo machinectl start {{name}}"

[group('machines')]
machine-disable name:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    if [ -z "{{name}}" ]; then echo "Usage: myosi machine-disable <name>" >&2; exit 2; fi
    validate_name "{{name}}" machine

    feature_disable "{{name}}" sysupdate.machines.d

    # Stop first — rm on a held .raw can fail on some kernels and silently leak.
    if machinectl show "{{name}}" >/dev/null 2>&1; then
        machinectl stop "{{name}}" 2>/dev/null || true
    fi

    rm -f /var/lib/machines/"{{name}}"_*.raw "/var/lib/machines/{{name}}.raw"
    rm -f /var/lib/sysupdate/"{{name}}"_*.raw

    sysupdate_env
    if command -v "$SYSUPDATE" >/dev/null; then
        "$SYSUPDATE" --component=machines vacuum 2>/dev/null || true
    fi

    echo "Disabled machine '{{name}}'."

[group('machines')]
machine-list:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    sysupdate_env

    echo "== available features =="
    if [ -d "$MACHINES_DIR" ]; then
        find "$MACHINES_DIR" -maxdepth 1 -name '*.feature' -printf '  %f\n' 2>/dev/null \
            | sed 's/\.feature$//' | sort
    fi
    echo
    if command -v "$SYSUPDATE" >/dev/null; then
        echo "== machines update sets =="
        "$SYSUPDATE" --component=machines list --no-pager 2>/dev/null | sed 's/^/  /' || true
        echo
    fi
    echo "== DDIs on disk (/var/lib/machines/) =="
    find /var/lib/machines -maxdepth 1 -type f -name '*.raw' -printf '  %f\n' 2>/dev/null | sort
    find /var/lib/machines -maxdepth 1 -type l -name '*.raw' -printf '  %f -> %l\n' 2>/dev/null | sort
    echo
    echo "== running machines =="
    machinectl list --no-legend --no-pager 2>/dev/null | sed 's/^/  /' || true
