# Enable, disable, and list machine DDI features (mybox today).
#
# Mirrors 10-extensions.just but targets /var/lib/machines/ instead of
# /var/lib/extensions/, and skips the systemd-sysext refresh step.
# Activation of an enabled machine is operator-driven via
# `machinectl start <name>`; reapplying an existing machine usually
# means `machinectl stop <name> && machinectl start <name>` since the
# running namespace pins the old image file.

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

    # mybox-style artifacts embed the architecture in the filename
    # (Output=%i_%v_%a in mkosi.images/<name>/mkosi.conf). Resolve to
    # systemd's UPPER_ARCH token so the asset name matches the release.
    ARCH=$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')
    ASSET="{{name}}_${VERSION}_${ARCH}.raw"
    TMPDIR=$(mktemp -d)
    trap "rm -rf '$TMPDIR'" EXIT
    echo "Downloading $ASSET from $REPO@$VERSION..."
    download_release_asset "$VERSION" "$ASSET" "$TMPDIR/$ASSET" "$REPO"

    # Land the new DDI as /var/lib/machines/{{name}}_<VER>_<ARCH>.raw —
    # the arch suffix matches sysupdate.machines.d/*.transfer's
    # MatchPattern (mybox_@v_%a.raw). Versioned filename keeps prior
    # installs around for rollback, InstancesMax=2 in the transfer
    # enforces retention. Operators symlink {{name}}.raw → desired
    # version when ready to flip.
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

    # NOT: refresh_sysext / machinectl restart. A running container
    # keeps the old .raw open via a held fd — restarting silently
    # would interrupt user sessions. Operator picks the moment:
    #   sudo machinectl stop {{name}}
    #   sudo ln -sf {{name}}_${VERSION}.raw /var/lib/machines/{{name}}.raw
    #   sudo machinectl start {{name}}
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

    # Stop the container first if it's running — otherwise rm fails on
    # the held .raw on some kernels and the file silently leaks.
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
