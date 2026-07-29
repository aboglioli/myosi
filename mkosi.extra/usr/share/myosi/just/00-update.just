# Update base image and enabled sysexts via cache-first sysupdate.
#
# All transfers read from /var/lib/sysupdate/ (populated by `fetch`).
# `apply` installs cached artifacts via the systemd-sysupdate binary;
# `update` does both. No live refresh by default — reboot is the
# normal activation path.
#
# We invoke the binary directly (surfaced as the short `sysupdate`
# symlink at /usr/local/bin/sysupdate, see mkosi.extra/) instead of
# going through `updatectl`. Reason: systemd-sysupdated runs in a
# tight SELinux context that silently denies the loop subsystem and
# dosfs_t writes on Fedora 44 selinux-policy. The binary inherits
# the calling shell's unconfined_t context and completes the same
# transfers without sandbox interference.
#
# To flip back to updatectl in the future (when policy ships
# systemd_sysupdate_t rules or we add a CIL module):
#   1. Set MYOSI_SYSUPDATE_BIN=updatectl in /etc/environment or in
#      sysupdate_env() (myosi/lib.sh).
#   2. Rewrite the call sites below: updatectl uses
#        verb target[@VERSION]
#      while systemd-sysupdate uses
#        --component=NAME verb [VERSION]
# Both engines read the same /usr/lib/sysupdate.d/*.transfer files
# and the same /var/lib/sysupdate cache, so artifacts and ordering
# stay identical.

# ------- fetch -----------------------------------------------------

[group('update')]
fetch version="":
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    require_gh

    REPO="${MYOSI_REPO:-user/myosi}"
    sysupdate_env
    ETC_EXT_DIR="/etc/sysupdate.extensions.d"
    ETC_MACHINES_DIR="/etc/sysupdate.machines.d"

    enabled_value_from_file() {
        local f="$1"
        [ -f "$f" ] || return 0
        awk -F= '/^[[:space:]]*Enabled[[:space:]]*=/{v=$2;gsub(/^[[:space:]]+|[[:space:]]+$/,"",v);print tolower(v)}' "$f" | tail -1
    }

    feature_is_enabled() {
        local n="$1" bd="$2" od="$3" s="false" v
        v=$(enabled_value_from_file "$bd/${n}.feature"); [ -z "$v" ] || s="$v"
        if [ -d "$od/${n}.feature.d" ]; then
            while IFS= read -r f; do
                v=$(enabled_value_from_file "$f"); [ -z "$v" ] || s="$v"
            done < <(find "$od/${n}.feature.d" -maxdepth 1 -type f -name '*.conf' | sort)
        fi
        case "$s" in true|yes|1|on) return 0;; *) return 1;; esac
    }

    VERSION=$(resolve_version "{{version}}" "$REPO")
    [ -n "$VERSION" ] || { echo "ERROR: failed to resolve release version" >&2; exit 3; }

    # Architecture token matches mkosi's %a specifier (and systemd's
    # specifier engine in sysupdate transfer MatchPattern=). The release
    # pipeline bakes %a into every artifact name (Output=%i_%v_%a on
    # every sub-image plus UnifiedKernelImageFormat=%i_%v_%a for the
    # UKI), so every download below filters to the host's native arch
    # without grabbing the wrong build.
    ARCH=$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')

    install -d -m 0755 "$CACHE"
    TMPDIR=$(mktemp -d)
    trap "rm -rf '$TMPDIR'" EXIT

    download() {
        local v="$1" a="$2"
        echo "Downloading $a from $REPO@$v..."
        gh release download "$v" --repo "$REPO" --pattern "$a" --dir "$TMPDIR" --clobber
        install -m 0644 "$TMPDIR/$a" "$CACHE/$a"
    }

    # root + verity ship with the PartitionUUID embedded in the
    # filename: myosi_<VER>_<ARCH>_<UUID>.root.raw.zst (first 16 bytes
    # of roothash) and myosi_<VER>_<ARCH>_<UUID>.verity.raw.zst (last
    # 16 bytes). The .transfer files capture the UUID via the `@u`
    # wildcard and write it into the GPT entry. gh CLI's --pattern
    # accepts globs, so we fetch with a wildcard for the UUID slot
    # and let sysupdate match by content.
    download_glob() {
        local v="$1" pattern="$2"
        echo "Downloading $pattern from $REPO@$v..."
        gh release download "$v" --repo "$REPO" --pattern "$pattern" \
            --dir "$TMPDIR" --clobber
    }
    download_glob "$VERSION" "myosi_${VERSION}_${ARCH}_*.root.raw.zst"
    download_glob "$VERSION" "myosi_${VERSION}_${ARCH}_*.verity.raw.zst"
    download_glob "$VERSION" "myosi_${VERSION}_${ARCH}.verity-sig.raw.zst"
    download_glob "$VERSION" "myosi_${VERSION}_${ARCH}.efi"
    # Install every downloaded host artifact into the cache.
    for f in "$TMPDIR"/myosi_"${VERSION}"_"${ARCH}"_*.root.raw.zst \
             "$TMPDIR"/myosi_"${VERSION}"_"${ARCH}"_*.verity.raw.zst \
             "$TMPDIR"/myosi_"${VERSION}"_"${ARCH}".verity-sig.raw.zst \
             "$TMPDIR"/myosi_"${VERSION}"_"${ARCH}".efi; do
        [ -f "$f" ] || continue
        install -m 0644 "$f" "$CACHE/$(basename "$f")"
    done

    # Sysexts ship as <feature>_<VER>_<ARCH>.raw (Output=%i_%v_%a on
    # every sysext sub-image). Filter to the host arch so we don't
    # pull an arm64 build on an x86-64 host or vice versa.
    for feature in $(find "$EXT_DIR" -maxdepth 1 -name '*.feature' -printf '%f\n' 2>/dev/null | sed 's/\.feature$//' | sort -u); do
        if feature_is_enabled "$feature" "$EXT_DIR" "$ETC_EXT_DIR"; then
            download "$VERSION" "${feature}_${VERSION}_${ARCH}.raw"
        fi
    done

    # Machine DDIs (mybox): same per-arch naming as sysexts.
    for feature in $(find "$MACHINES_DIR" -maxdepth 1 -name '*.feature' -printf '%f\n' 2>/dev/null | sed 's/\.feature$//' | sort -u); do
        if feature_is_enabled "$feature" "$MACHINES_DIR" "$ETC_MACHINES_DIR"; then
            download "$VERSION" "${feature}_${VERSION}_${ARCH}.raw"
        fi
    done

    rm -rf "$TMPDIR"
    trap - EXIT
    echo "Fetched myosi artifacts for $VERSION into $CACHE."

# ------- apply -----------------------------------------------------

[group('update')]
apply version="" refresh="":
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root

    sysupdate_env
    VERSION="{{version}}"
    REFRESH="{{refresh}}"

    command -v "$SYSUPDATE" >/dev/null || { echo "ERROR: $SYSUPDATE is required" >&2; exit 4; }

    # Preflight: validate cache when a specific version was requested.
    # root + verity ship as myosi_<VER>_<ARCH>_<UUID>.{root,verity}.raw.zst
    # — the UUID is computed from the verity roothash and the .transfer
    # files capture it via the @u wildcard. Match by glob; pin the
    # architecture to the host so we don't accept a wrong-arch cache.
    ARCH=$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')
    if [ -n "$VERSION" ]; then
        missing=()
        shopt -s nullglob
        root_glob=( "$CACHE"/myosi_"${VERSION}"_"${ARCH}"_*.root.raw.zst )
        verity_glob=( "$CACHE"/myosi_"${VERSION}"_"${ARCH}"_*.verity.raw.zst )
        [ "${#root_glob[@]}" -gt 0 ]   || missing+=("myosi_${VERSION}_${ARCH}_<UUID>.root.raw.zst")
        [ "${#verity_glob[@]}" -gt 0 ] || missing+=("myosi_${VERSION}_${ARCH}_<UUID>.verity.raw.zst")
        for asset in \
            "myosi_${VERSION}_${ARCH}.verity-sig.raw.zst" \
            "myosi_${VERSION}_${ARCH}.efi"; do
            [ -f "$CACHE/$asset" ] || missing+=("$asset")
        done
        if [ "${#missing[@]}" -gt 0 ]; then
            echo "ERROR: cache $CACHE is missing required artifacts:" >&2
            printf '  %s\n' "${missing[@]}" >&2
            echo "       Run 'myosi fetch $VERSION' first, or 'myosi update $VERSION'." >&2
            exit 5
        fi
    else
        echo "WARN: 'apply' without an explicit version skips preflight." >&2
    fi

    components=()
    [ -d "$SU_DIR" ]       && ls "$SU_DIR"/*.transfer       >/dev/null 2>&1 && components+=(host)
    [ -d "$EXT_DIR" ]      && ls "$EXT_DIR"/*.transfer      >/dev/null 2>&1 && components+=(extensions)
    [ -d "$MACHINES_DIR" ] && ls "$MACHINES_DIR"/*.transfer >/dev/null 2>&1 && components+=(machines)

    for c in "${components[@]}"; do
        cmd=("$SYSUPDATE")
        [ "$c" = host ] || cmd+=(--component="$c")
        cmd+=(update)
        [ -n "$VERSION" ] && [ "$VERSION" != latest ] && cmd+=("$VERSION")
        "${cmd[@]}"
    done

    if [ "$REFRESH" = "true" ]; then
        refresh_sysext
        echo "Refreshed active sysext overlay. Restart affected services manually."
    fi

    echo "Applied cached myosi artifacts${VERSION:+ for $VERSION}. Reboot to activate staged updates."
    [ "$REFRESH" = "true" ] || \
        echo "Run 'systemd-sysext refresh' for live extension activation."

# ------- update ----------------------------------------------------

[group('update')]
update version="" refresh="":
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    require_gh

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

    V=$(resolve_version "$raw_version")
    [ -n "$V" ] || { echo "ERROR: failed to resolve release version" >&2; exit 3; }
    just -f /usr/share/myosi/just/00-update.just fetch "$V"
    just -f /usr/share/myosi/just/00-update.just apply "$V" "$REFRESH"

# ------- status ----------------------------------------------------

[group('update')]
status:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    sysupdate_env

    if command -v "$SYSUPDATE" >/dev/null; then
        echo "== host =="
        "$SYSUPDATE" list --no-pager 2>/dev/null | sed 's/^/  /' || true
        echo
        if [ -d "$EXT_DIR" ] && ls "$EXT_DIR"/*.transfer >/dev/null 2>&1; then
            echo "== extensions =="
            "$SYSUPDATE" --component=extensions list --no-pager 2>/dev/null | sed 's/^/  /' || true
        fi
        if [ -d "$MACHINES_DIR" ] && ls "$MACHINES_DIR"/*.transfer >/dev/null 2>&1; then
            echo "== machines =="
            "$SYSUPDATE" --component=machines list --no-pager 2>/dev/null | sed 's/^/  /' || true
            echo
        fi
    fi

    echo "== cached artifacts =="
    find "$CACHE" -maxdepth 1 -type f -printf '  %f\n' 2>/dev/null | sort || true
    echo
    echo "== sysexts on disk =="
    find /var/lib/extensions /usr/lib/extensions -maxdepth 1 -type f -name '*.raw' -printf '  %p\n' 2>/dev/null | sort
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
    if [ -d "$EXT_DIR" ] && ls "$EXT_DIR"/*.transfer >/dev/null 2>&1; then
        "$SYSUPDATE" --component=extensions vacuum 2>/dev/null || true
    fi
    if [ -d "$MACHINES_DIR" ] && ls "$MACHINES_DIR"/*.transfer >/dev/null 2>&1; then
        "$SYSUPDATE" --component=machines vacuum 2>/dev/null || true
    fi
