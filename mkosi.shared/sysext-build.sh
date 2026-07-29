# shellcheck shell=bash
# Atoms sourced by every sysext mkosi.postinst. Close out with
# `sysext_finalize "$@"`: gates on the final stage, strips dnf, stages
# SELinux file_contexts for mkfs.erofs, strips to the /usr,/opt layout.
# Extension-release files are written directly at the versioned path
# (see sysext_extension_release_path). systemd-sysext matches the
# <imageid>_<version> basename strictly — keep versioned filenames
# even for manual uploads. Confexts don't source this file.

stage_sysext_policy() {
    local buildroot="${BUILDROOT:?BUILDROOT must be set by mkosi}"
    local policy="$buildroot/etc/selinux/targeted/contexts/files/file_contexts"

    if [ ! -f "$policy" ]; then
        echo "sysext-build: $policy missing — sysext payload will ship without baked SELinux labels" >&2
        return 1
    fi

    mkdir -p "$buildroot/usr/share/myosi"
    install -m 0644 "$policy" "$buildroot/usr/share/myosi/file_contexts"
}

strip_to_sysext_layout() {
    local buildroot="${BUILDROOT:?BUILDROOT must be set by mkosi}"

    # Drop leftover bind mounts before the rm walk — find -exec rm -rf
    # would recurse into a live /proc and EPERM-cascade.
    local mp
    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        [ "$mp" = "$buildroot" ] && continue
        umount -l "$mp" 2>/dev/null || true
    done < <(findmnt -rn -o TARGET --submounts "$buildroot" 2>/dev/null | sort -r)

    # Also exclude mount-point dirs in the find itself, in case a mount
    # survived the unmount loop (rootless can lose CAP_SYS_ADMIN).
    find "$buildroot" -mindepth 1 -maxdepth 1 \
        ! -name usr ! -name opt \
        ! -name proc ! -name sys ! -name dev ! -name run ! -name tmp \
        -exec rm -rf {} +
    # Drop the now-empty mount-point dirs.
    for mp in proc sys dev run tmp; do
        rmdir "$buildroot/$mp" 2>/dev/null || true
    done

    # Strip the GSettings compiled cache from every sysext: each build
    # chroot's cache is a partial view, and the topmost overlay layer
    # shadows all others ("Settings schema ... is not installed").
    # XML schemas still merge; myosi-glib-schemas-compile.service
    # compiles a union cache at boot and GSETTINGS_SCHEMA_DIR points at it.
    rm -f "$buildroot/usr/share/glib-2.0/schemas/gschemas.compiled"
}

stage_sandbox_repos() {
    local buildroot="${BUILDROOT:?BUILDROOT must be set by mkosi}"
    local srcdir="${SRCDIR:?SRCDIR must be set by mkosi}"
    local repo_dir="$srcdir/mkosi.sandbox/etc/yum.repos.d"
    local repo_files=("$repo_dir"/*.repo)

    if [ ! -d "$repo_dir" ]; then
        echo "sysext-build: $repo_dir missing" >&2
        return 1
    fi
    if [ ! -e "${repo_files[0]}" ]; then
        echo "sysext-build: $repo_dir has no .repo files" >&2
        return 1
    fi
    mkdir -p "$buildroot/etc/yum.repos.d"
    cp -a "${repo_files[@]}" "$buildroot/etc/yum.repos.d/"
}

# Unit activation in sysexts/profiles is DECLARATIVE only: ship static
# .wants/ symlinks under mkosi.extra/usr/lib/systemd/. Preset-shipped
# /etc symlinks die in strip_to_sysext_layout; /usr/lib ones survive,
# and the same artifact covers baked-profile and runtime-sysext modes.

# No sysext ships dnf: sealed verity /usr means no in-place upgrades,
# so it's ~30 MiB dead weight (some sysexts need it at BUILD time).
# Not via RemovePackages=: dnf5 is in Fedora's protected list (refuses
# removal) and mkosi v26 errors on never-installed packages. rpm -e
# --nodeps --noscripts bypasses both; idempotent via sysext_finalize.
strip_buildroot_dnf() {
    local buildroot="${BUILDROOT:?BUILDROOT must be set by mkosi}"
    [ -d "$buildroot/usr/lib/sysimage/rpm" ] || [ -d "$buildroot/var/lib/rpm" ] || return 0

    rm -f "$buildroot"/etc/dnf/protected.d/*.conf 2>/dev/null || true

    local pkgs
    pkgs=$(chroot "$buildroot" rpm -qa --queryformat '%{NAME}\n' 2>/dev/null \
        | grep -E '^(dnf5|dnf5-plugins|python3-dnf5|python3-libdnf5|libdnf5|libdnf5-cli|dnf|dnf-plugins-core)$' \
        | sort -u || true)
    [ -n "$pkgs" ] || return 0

    # shellcheck disable=SC2086
    chroot "$buildroot" rpm -e --nodeps --noscripts $pkgs 2>/dev/null || true
}

# Versioned extension-release filenames let two versions of a sysext
# coexist in /var/lib/extensions/ (current + last-good): systemd-sysext
# groups by IMAGE_ID and merges only the highest version. Unversioned
# names would collapse layers via overlayfs highest-wins.
# Arch token mirrors mkosi's %a specifier; falls back to uname -m for
# runs where mkosi hasn't exported ARCHITECTURE=.
sysext_arch() {
    if [ -n "${ARCHITECTURE:-${MKOSI_ARCHITECTURE:-}}" ]; then
        printf '%s' "${ARCHITECTURE:-${MKOSI_ARCHITECTURE}}"
        return 0
    fi
    uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/'
}

# Path must be EXACTLY extension-release.<id>_<version>_<arch> (mkosi
# v26 with Output=%i_%v_%a): land our file there first and mkosi's
# configure_extension_release() augments it in place, so our extras
# (EXTENSION_RELOAD_MANAGER, SYSEXT_KERNEL_RELEASE) survive. A wrong
# basename makes mkosi write its OWN file and ours is silently ignored.
sysext_extension_release_path() {
    local buildroot="${BUILDROOT:?BUILDROOT must be set by mkosi}"
    local name="${1:?sysext name required}"
    local version="${IMAGE_VERSION:-dev}"
    local arch
    arch="$(sysext_arch)"
    printf '%s/usr/lib/extension-release.d/extension-release.%s_%s_%s\n' \
        "$buildroot" "$name" "$version" "$arch"
}

# Write the extension-release file at the versioned path in one shot.
# Args: $1 = SYSEXT_ID (also filename stem); $@ = extra KEY=VALUE lines
# (e.g. SYSEXT_KERNEL_RELEASE=$KVER for kmod sysexts).
sysext_write_extension_release() {
    local name="${1:?sysext name required}"
    shift
    local version="${IMAGE_VERSION:-dev}"
    local f
    f="$(sysext_extension_release_path "$name")"

    local arch
    arch="$(sysext_arch)"
    mkdir -p "$(dirname "$f")"
    {
        printf 'ID=fedora\n'
        printf 'VERSION_ID=44\n'
        printf 'ARCHITECTURE=%s\n' "$arch"
        printf 'SYSEXT_LEVEL=1\n'
        printf 'SYSEXT_SCOPE=system\n'
        printf 'SYSEXT_IMAGE_VERSION=%s\n' "$version"
        # EXTENSION_RELOAD_MANAGER=1 makes systemd-sysext issue one
        # Manager.Reload() after the merge batch — without it sysext-
        # shipped Upholds=/.wants units never auto-start at first boot.
        printf 'EXTENSION_RELOAD_MANAGER=1\n'
        local kv
        for kv in "$@"; do
            printf '%s\n' "$kv"
        done
    } > "$f"
}

# Default close-out (`sysext_finalize "$@"`); exits 0 unless mkosi is
# invoking the `final` stage.
sysext_finalize() {
    [ "${1:-final}" = "final" ] || exit 0
    strip_buildroot_dnf
    stage_sysext_policy
    strip_to_sysext_layout
}
