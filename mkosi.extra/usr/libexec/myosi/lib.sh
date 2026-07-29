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

require_gh() {
    if ! command -v gh >/dev/null; then
        echo "ERROR: gh CLI required; install it and run 'gh auth login'" >&2
        exit 2
    fi
    gh auth status --hostname github.com >/dev/null
}

validate_name() {
    local name="$1" label="${2:-name}"
    case "$name" in
        *[!A-Za-z0-9_.-]*) echo "ERROR: invalid ${label}: $name" >&2; exit 3;;
    esac
}

# Check whether gh is installed AND authenticated against github.com.
_gh_auth_ok() {
    command -v gh >/dev/null && gh auth status --hostname github.com >/dev/null 2>&1
}

# Return a GitHub auth token from any available source: explicit env
# vars first, then gh's stored token. Empty if none — caller decides
# whether that is fatal.
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

# Build curl args for an authenticated GitHub API request when a token
# is available. Echoes the args one per line so callers can read into
# an array safely.
_gh_curl_auth_args() {
    local tok
    tok=$(_gh_token)
    if [ -n "$tok" ]; then
        printf -- '-H\n'
        printf 'Authorization: Bearer %s\n' "$tok"
    fi
}

# Pass an explicit calver through unchanged; resolve "latest" (or an
# empty input) via resolve_latest_release. Used by every recipe that
# takes an optional version argument.
resolve_version() {
    local v="${1:-}" repo="${2:-${MYOSI_REPO:-user/myosi}}"
    if [ -n "$v" ] && [ "$v" != latest ]; then
        printf '%s\n' "$v"
        return 0
    fi
    resolve_latest_release "$repo"
}

resolve_latest_release() {
    local repo="${1:-user/myosi}"
    local version=""
    # Prefer gh when present + authed (private repos require auth; gh
    # already has a working token, no need to plumb one in).
    if _gh_auth_ok; then
        version=$(gh release view --repo "$repo" --json tagName --jq .tagName 2>/dev/null || true)
    fi
    # Curl fallback: works on public repos unauthenticated; on private
    # repos picks up MYOSI_GH_TOKEN / GH_TOKEN / GITHUB_TOKEN / `gh auth
    # token` and sends Authorization on the api.github.com request. The
    # asset download itself redirects to S3 with a signed URL where the
    # auth header is no longer needed (and curl drops it on cross-host
    # redirect without --location-trusted).
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        local auth_args=()
        mapfile -t auth_args < <(_gh_curl_auth_args)
        version=$(curl -fsSL "${auth_args[@]}" \
                "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
            | head -1)
    fi
    if [ -z "$version" ]; then
        echo "ERROR: failed to resolve latest release" >&2
        exit 4
    fi
    printf '%s\n' "$version"
}

# List asset names attached to a release. Tries gh first, falls back to
# the REST API via curl with an auth token (if any). Used by callers
# that need to discover whether a release ships a single full image or
# split parts (myosi_<ver>.raw.zst vs myosi_<ver>.raw.zst.part00...).
list_release_assets() {
    local version="$1" repo="${2:-user/myosi}"
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

# Download a single release asset by exact name to <dest>. Tries gh
# first; on failure (or when gh is not authed) falls back to the REST
# API via curl, which works for private repos when a token is in env or
# gh's auth store. Returns nonzero on any failure.
download_release_asset() {
    local version="$1" name="$2" dest="$3" repo="${4:-user/myosi}"
    if _gh_auth_ok; then
        if gh release download "$version" --repo "$repo" \
                --pattern "$name" --output "$dest" --clobber 2>/dev/null; then
            return 0
        fi
        echo "WARN: gh download failed for $name, trying curl fallback" >&2
    fi
    # Curl path: hit the assets API to get the per-asset id+url, then
    # fetch the binary with Accept: application/octet-stream. GitHub
    # returns a 302 to a signed S3 URL; -L follows it and the redirect
    # strips Authorization (cross-host) — which is correct, the S3 URL
    # is already pre-signed.
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

# Walk dm-mapper slaves and partition->disk via sysfs to reach the
# underlying physical disk from any mount source. e.g. /dev/mapper/root
# (dm-verity over /dev/sda3) resolves to /dev/sda. Echoes empty on
# overlay / unresolvable sources.
resolve_boot_disk() {
    local source cur
    source=$(findmnt -no SOURCE / 2>/dev/null || true)
    if [ -z "$source" ] || [ "$source" = overlay ]; then
        return 0
    fi
    cur=$(basename "$source")
    while [ -e "/sys/class/block/$cur" ]; do
        if [ -d "/sys/class/block/$cur/slaves" ] \
                && [ -n "$(ls -A "/sys/class/block/$cur/slaves" 2>/dev/null)" ]; then
            cur=$(ls "/sys/class/block/$cur/slaves" | head -1)
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

# Populate SYSUPDATE / SU_DIR / EXT_DIR / CACHE globals from env or
# defaults. Source-once-and-use across every recipe that touches the
# sysupdate engine or its cache. Globals, not locals — the caller's
# shell needs to see them after this function returns.
sysupdate_env() {
    # Default backend is /usr/lib/systemd/systemd-sysupdate, surfaced as
    # the `sysupdate` symlink at /usr/local/bin/sysupdate so recipes
    # invoke a short PATH command. We talk to the binary directly
    # instead of going through `updatectl` because systemd-sysupdated
    # runs in a tight SELinux + sandbox context that blocks the loop
    # subsystem and writes to /efi (dosfs_t) on Fedora 44 — the
    # canonical CLI silently fails on ESP updates until selinux-policy
    # ships systemd_sysupdate_t rules or we ship our own CIL module.
    # The direct binary inherits the calling shell's unconfined_t
    # context and just works.
    #
    # To flip to updatectl later (when policy catches up): override
    # MYOSI_SYSUPDATE_BIN=updatectl and update the recipe argument
    # forms — updatectl uses `verb target[@version]` (e.g.
    # `updatectl update host@VER`) while systemd-sysupdate uses flag
    # form (`systemd-sysupdate --component=NAME verb [VER]`).
    SYSUPDATE="${MYOSI_SYSUPDATE_BIN:-sysupdate}"
    SU_DIR="${MYOSI_SYSUPDATE_DIR:-/usr/lib/sysupdate.d}"
    EXT_DIR="${MYOSI_SYSUPDATE_EXTENSIONS_DIR:-/usr/lib/sysupdate.extensions.d}"
    # Machines component — opt-in nspawn DDI updates (mybox today,
    # potential additional containers later). Separate dir from
    # sysupdate.extensions.d because the post-apply step differs:
    # sysexts call `systemctl restart systemd-sysext.service` to
    # remerge into the host /usr, machine DDIs require
    # `machinectl restart <name>` or a scheduled reboot of the
    # container. Recipe code paths must NOT cross-wire the two.
    MACHINES_DIR="${MYOSI_SYSUPDATE_MACHINES_DIR:-/usr/lib/sysupdate.machines.d}"
    CACHE="${MYOSI_RELEASE_CACHE:-/var/lib/sysupdate}"
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

    # sysusers / binfmt / sysctl / tmpfiles replay is ALREADY done by
    # systemd-sysext.service.d/10-myosi-rerun-sysinit.conf ExecStartPost
    # (fires inside the restart above). No need to call them again here.
    #
    # SELinux relabel of /etc is NOT in sysext.service ExecStartPost
    # because restorecon's typical "first do other replays so /etc has
    # final shape" pattern needs to outlive any single sysext.service
    # invocation. Keep it as its own restart here.
    systemctl restart myosi-sysext-relabel.service 2>/dev/null || true

    # Kmod sysexts (nvidia, nvidia-580xx, zfs, ...) ship .ko files at
    # /usr/lib/modules/<KVER>/extra/<sysext>/, but mkosi v26's
    # path-based dedup strips modules.dep from the sysext at seal time
    # — see /usr/libexec/myosi/sysext-modules-refresh for the long-form. The
    # restart of systemd-sysext.service above (which runs
    # sysext-modules-refresh as ExecStartPost) ALREADY regenerates indices and
    # modprobes everything in modules-load.d. The standalone
    # myosi-depmod.service is retired; no separate call needed here.

    # GSettings schemas are XML files merged from every active sysext;
    # per-sysext gschemas.compiled caches are stripped at build time to
    # avoid overlay precedence bugs. Rebuild the runtime union cache now
    # so live extension-enable sees the same schema set as next boot.
    systemctl restart myosi-glib-schemas-compile.service 2>/dev/null || true

    # Bind user to sysext-introduced groups (libvirt, incus-admin)
    # that the freshly merged sysext just brought online. Sysext's own
    # sysusers.d created the group via systemd-sysusers (run inside
    # systemd-sysext.service ExecStartPost above). The homed-user
    # template's bind phase idempotently adds user to each
    # present group declared under /usr/share/myosi/user-groups.d/.
    # Effect is visible at NEXT login (initgroups re-evaluates
    # supplementary GIDs then). `systemctl start` re-runs the oneshot
    # (RemainAfterExit=no) — the create phase is gated by `homectl
    # inspect` so it no-ops when the user already exists.
    systemctl start myosi-homed-user@user.service 2>/dev/null || true

    # DBus + polkit caches their service / policy registries at startup
    # and do NOT re-scan /usr/share/dbus-1/ or /usr/share/polkit-1/ on
    # sysext merge. Without a reload, a freshly merged sysext that
    # ships a DBus-activated daemon (desktop sysext ships
    # /usr/share/dbus-1/system-services/org.freedesktop.Flatpak.SystemHelper.service)
    # shows up as "The name is not activatable" — operator-visible
    # failure observed running `flatpak install` right after
    # `sudo myosi extension-enable desktop`. dbus-broker is the modern
    # default on Fedora 44; fall through to dbus.service for setups
    # still on the legacy daemon. polkit caches its .rules and .pkla,
    # so authorization for sysext-shipped services (NetworkManager,
    # systemd1, ...) also needs a refresh.
    systemctl reload dbus-broker.service 2>/dev/null \
        || systemctl reload dbus.service 2>/dev/null || true
    systemctl reload polkit.service 2>/dev/null || true

    # ldconfig cache misses sysext-shipped library directories. Fedora's
    # pipewire-jack-audio-connection-kit drops libjack.so.0 under
    # /usr/lib64/pipewire-0.3/jack/ and the matching ld.so.conf.d entry
    # under /etc/ — but sysexts only ship /usr/, so the conf goes through
    # /usr/lib/ld.so.conf.d/ instead. The dynamic linker reads both
    # search dirs, but the cache must be refreshed for new entries to be
    # picked up without a process restart. Observed failure: waybar
    # under niri refused to launch with
    #   "libjack.so.0: cannot open shared object file: No such file or directory"
    # after `sudo myosi extension-enable desktop`, until `sudo ldconfig`
    # ran. Always refresh the cache here.
    ldconfig 2>/dev/null || true
}

# Shorthand for the common "enable feature gate, run updater, refresh sysext".
update_and_refresh() {
    local name="$1" version="${2:-}"
    if [ -n "$version" ]; then
        /usr/libexec/myosi/update run "$version"
    else
        /usr/libexec/myosi/update run
    fi
    refresh_sysext
}
