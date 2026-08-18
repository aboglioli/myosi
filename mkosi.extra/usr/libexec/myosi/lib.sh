# shellcheck shell=bash
# Shared helpers sourced by /usr/libexec/myosi/* scripts.
# Source this at the top of every operator script:
#   UPDATER=$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)
#   . "${UPDATER}/lib.sh"

require_root() {
    if [ "$EUID" -ne 0 ] && [ "${MYOSI_ALLOW_NON_ROOT:-}" != 1 ]; then
        echo "ERROR: must run as root" >&2
        exit 1
    fi
}

validate_name() {
    local name="$1" label="${2:-name}"
    case "$name" in
        *[!A-Za-z0-9_.-]*) echo "ERROR: invalid ${label}: $name" >&2; exit 3;;
    esac
}

# Release source, most specific first: an explicit caller argument, then
# $MYOSI_REPO, then /etc/myosi/repo (written by `myosi set-repo` — lives on
# the persistent /etc subvol, so it survives A/B image updates), then the
# upstream default baked into the image. Forks override without a rebuild.
MYOSI_DEFAULT_REPO=aboglioli/myosi

myosi_repo() {
    local line stripped
    if [ -n "${MYOSI_REPO:-}" ]; then
        printf '%s\n' "$MYOSI_REPO"
        return 0
    fi
    if [ -r /etc/myosi/repo ]; then
        # No pipeline: a `head -1` here can SIGPIPE the read under pipefail.
        while IFS= read -r line || [ -n "$line" ]; do
            stripped=${line%%#*}
            stripped=${stripped//[[:space:]]/}
            if [ -n "$stripped" ]; then
                printf '%s\n' "$stripped"
                return 0
            fi
        done < /etc/myosi/repo
    fi
    printf '%s\n' "$MYOSI_DEFAULT_REPO"
}

_gh_auth_ok() {
    command -v gh >/dev/null && gh auth status --hostname github.com >/dev/null 2>&1
}

# Token from env vars first, then gh's store. Empty if none — caller decides.
_gh_token() {
    local v
    for v in "${MYOSI_GH_TOKEN:-}" "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}"; do
        if [ -n "$v" ]; then
            printf '%s' "$v"
            return 0
        fi
    done
    if command -v gh >/dev/null; then
        gh auth token 2>/dev/null || true
    fi
}

# Curl auth args, echoed one per line so callers can mapfile into an array.
_gh_curl_auth_args() {
    local tok
    tok=$(_gh_token)
    if [ -n "$tok" ]; then
        printf -- '-H\n'
        printf 'Authorization: Bearer %s\n' "$tok"
    fi
}

# Explicit calver passes through; "latest"/empty resolves via the release API.
resolve_version() {
    local v="${1:-}" repo="${2:-$(myosi_repo)}"
    if [ -n "$v" ] && [ "$v" != latest ]; then
        printf '%s\n' "$v"
        return 0
    fi
    resolve_latest_release "$repo"
}

resolve_latest_release() {
    local repo="${1:-$(myosi_repo)}"
    local version=""
    # Prefer gh when present + authed (private repos require auth).
    if _gh_auth_ok; then
        version=$(gh release view --repo "$repo" --json tagName --jq .tagName 2>/dev/null || true)
    fi
    # Curl fallback: unauthenticated on public repos, token-authed on private.
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        local auth_args=()
        mapfile -t auth_args < <(_gh_curl_auth_args)
        # Single-pass awk consumes all input — a trailing head -1 can
        # SIGPIPE curl under pipefail.
        version=$(curl -fsSL "${auth_args[@]}" \
                "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | awk -F'"' '/"tag_name":/ && v=="" {v=$4} END{if(v!="")print v}')
    fi
    if [ -z "$version" ]; then
        echo "ERROR: failed to resolve latest release" >&2
        exit 4
    fi
    printf '%s\n' "$version"
}

# List release asset names (gh first, REST fallback) — callers use this to
# detect single-file vs split .partNN releases.
list_release_assets() {
    local version="$1" repo="${2:-$(myosi_repo)}"
    if _gh_auth_ok; then
        if gh release view "$version" --repo "$repo" \
                --json assets --jq '.assets[].name' 2>/dev/null; then
            return 0
        fi
    fi
    local auth_args=()
    mapfile -t auth_args < <(_gh_curl_auth_args)
    curl -fsSL "${auth_args[@]}" \
            "https://api.github.com/repos/${repo}/releases/tags/${version}" 2>/dev/null \
        | sed -n 's/.*"name": *"\([^"]*\)".*/\1/p'
}

# Download one asset by exact name to <dest>. Public repo: plain curl on
# the stable per-tag URL, no auth. Falls back to gh, then the token-authed
# assets API (still works if the repo ever goes private). Nonzero on failure.
download_release_asset() {
    local version="$1" name="$2" dest="$3" repo="${4:-$(myosi_repo)}"
    if curl -fsSL -o "$dest" \
            "https://github.com/${repo}/releases/download/${version}/${name}" 2>/dev/null; then
        return 0
    fi
    if _gh_auth_ok; then
        if gh release download "$version" --repo "$repo" \
                --pattern "$name" --output "$dest" --clobber 2>/dev/null; then
            return 0
        fi
        echo "WARN: gh download failed for $name, trying curl fallback" >&2
    fi
    # Assets API → per-asset url, fetched with Accept: octet-stream. GitHub
    # 302s to a pre-signed S3 URL; curl drops Authorization on the cross-host
    # redirect, which is correct here.
    local tok
    tok=$(_gh_token)
    if [ -z "$tok" ]; then
        echo "ERROR: no auth token (set MYOSI_GH_TOKEN, GH_TOKEN, GITHUB_TOKEN, or run 'gh auth login')" >&2
        return 1
    fi
    local asset_url
    asset_url=$(curl -fsSL -H "Authorization: Bearer $tok" \
            "https://api.github.com/repos/${repo}/releases/tags/${version}" 2>/dev/null \
        | awk -v want="\"$name\"" '
            /"name":/ { gsub(/[",]/,""); n=$2 }
            /"url":/  && n==want && !found && /\/assets\// {
                gsub(/[",]/,""); print $2; found=1
            }')
    if [ -z "$asset_url" ]; then
        echo "ERROR: asset '$name' not found in release '$version'" >&2
        return 1
    fi
    curl -fL -o "$dest" \
        -H "Authorization: Bearer $tok" \
        -H "Accept: application/octet-stream" \
        "$asset_url"
}

# Walk dm slaves + partition→disk sysfs links from the / mount source down to
# the physical disk (/dev/mapper/root → /dev/sda). Empty on overlay/unresolvable.
resolve_boot_disk() {
    local source cur
    source=$(findmnt -no SOURCE / 2>/dev/null || true)
    if [ -z "$source" ] || [ "$source" = overlay ]; then
        return 0
    fi
    # Canonicalize first: sysfs indexes dm devices as dm-N, so the
    # /dev/mapper/root NAME never matches /sys/class/block/* and the walk
    # would bail out returning a bogus /dev/root — which silently disabled
    # both the live-disk clone source and the booted-disk overwrite guard.
    cur=$(basename "$(readlink -f "$source")")
    while [ -e "/sys/class/block/$cur" ]; do
        if [ -d "/sys/class/block/$cur/slaves" ] \
                && [ -n "$(ls -A "/sys/class/block/$cur/slaves" 2>/dev/null)" ]; then
            cur=$(cd "/sys/class/block/$cur/slaves" && set -- *; printf '%s' "$1")
            continue
        fi
        if [ -e "/sys/class/block/$cur/partition" ]; then
            cur=$(basename "$(readlink -f "/sys/class/block/$cur/..")")
            continue
        fi
        break
    done
    echo "/dev/$cur"
}

# Populate SYSUPDATE / SU_DIR / STORE globals from env or defaults
# (globals on purpose — callers use them after return).
sysupdate_env() {
    # Direct systemd-sysupdate binary (the `sysupdate` symlink), NOT updatectl:
    # systemd-sysupdated's SELinux sandbox on Fedora 44 blocks the loop
    # subsystem and /efi (dosfs_t) writes, silently failing ESP updates until
    # policy ships systemd_sysupdate_t rules. The binary runs unconfined_t.
    # Flip via MYOSI_SYSUPDATE_BIN=updatectl — note its arg form differs
    # (`verb target[@ver]` vs `--component=NAME verb [ver]`).
    SYSUPDATE="${MYOSI_SYSUPDATE_BIN:-sysupdate}"
    # One dir for base + sysext transfers: shared @v means sysupdate only
    # offers versions complete across every enabled transfer — atomic
    # base+sysext generations. Feature files live here too.
    SU_DIR="${MYOSI_SYSUPDATE_DIR:-/usr/lib/sysupdate.d}"
    # Versioned sysext store (sysupdate target); sysext-select exposes one
    # version per name into /var/lib/extensions.
    STORE="${MYOSI_SYSEXT_STORE:-/var/lib/myosi/extensions}"
}

feature_enable() {
    local name="$1" base_dir="$2"
    install -d -m 0755 "/etc/${base_dir}/${name}.feature.d"
    printf '[Feature]\nEnabled=true\n' \
        > "/etc/${base_dir}/${name}.feature.d/enable.conf"
}

feature_disable() {
    local name="$1" base_dir="$2"
    rm -f "/etc/${base_dir}/${name}.feature.d/enable.conf"
    rmdir "/etc/${base_dir}/${name}.feature.d" 2>/dev/null || true
}

refresh_sysext() {
    systemctl enable systemd-sysext.service >/dev/null 2>&1 || true
    systemctl restart systemd-sysext.service 2>/dev/null || {
        echo "Extension merge not active. Reboot to activate." >&2
        return
    }

    # sysusers/binfmt/sysctl/tmpfiles replay and the kmod index rebuild
    # (sysext-modules-refresh; mkosi v26 strips modules.dep from sysexts)
    # already run via systemd-sysext.service ExecStartPost — don't repeat.
    # /etc SELinux relabel stays its own unit: restorecon must run after all
    # replays, outliving any single sysext.service invocation.
    systemctl restart myosi-sysext-relabel.service 2>/dev/null || true

    # Rebuild the runtime GSettings union cache (per-sysext gschemas.compiled
    # are stripped at build time to avoid overlay precedence bugs).
    systemctl restart myosi-glib-schemas-compile.service 2>/dev/null || true

    # Only ENABLED instances: `systemctl start` ignores enablement, so
    # hardcoding @user would create the generic user on hosts that never
    # enabled it. Applies at next login.
    for _link in /etc/systemd/system/multi-user.target.wants/myosi-homed-user@*.service \
                 /usr/lib/systemd/system/multi-user.target.wants/myosi-homed-user@*.service; do
        [ -e "$_link" ] || continue
        systemctl start "${_link##*/}" 2>/dev/null || true
    done
    unset _link

    # DBus + polkit don't rescan /usr/share on sysext merge — freshly merged
    # DBus-activated services report "The name is not activatable" (seen with
    # flatpak SystemHelper right after extension-enable desktop). Reload both;
    # dbus-broker is the F44 default, dbus.service is the legacy fallback.
    systemctl reload dbus-broker.service 2>/dev/null \
        || systemctl reload dbus.service 2>/dev/null || true
    systemctl reload polkit.service 2>/dev/null || true

    # ldconfig cache misses sysext-shipped lib dirs (e.g. pipewire's
    # libjack.so.0): waybar failed to launch after extension-enable desktop
    # until ldconfig ran. Always refresh.
    ldconfig 2>/dev/null || true
}
