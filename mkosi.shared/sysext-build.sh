# shellcheck shell=bash
# Atoms sourced by every sysext mkosi.postinst.
#
# Standard close-out: call `sysext_finalize "$@"` at the end. It
# gates on the `final` mkosi stage, stages the SELinux file_contexts
# under /usr (so mkfs.erofs --file-contexts can bake correct xattrs),
# then strips the buildroot down to the /usr,/opt sysext layout.
#
# If you need a different sequence, the underlying atoms
# (stage_sysext_policy, strip_to_sysext_layout) are exported too.
#
# Filename convention: each sysext's postinst writes its
# extension-release file directly at the versioned path
# /usr/lib/extension-release.d/extension-release.<imageid>_<version>
# via sysext_extension_release_path() — no placeholder substitution,
# no rename pass. mkosi v26's configure_extension_release() finds the
# pre-written file at that exact path and augments missing required
# fields in place. Default systemd-sysext match is strict against
# <imageid>_<version> basename. Operator workflow:
#   - extension-enable / sysupdate keep the versioned name from the release
#     asset → strict match works.
#   - Manual rename to <imageid>.raw → won't merge until version stripped from
#     extension-release inside, or until SYSTEMD_SYSEXT_HIERARCHIES env tricks
#     are used. Stick to versioned names for manual uploads too.
# Version is always queryable via `systemd-sysext list` and `systemd-dissect`
# regardless of filename.
#
# Confexts have their own /etc-only flow; they don't source this file.

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

    # Belt-and-braces: drop any leftover bind mounts that the kmod
    # build, dnf5 rpm-scriptlet pass, or akmods left under $buildroot
    # before the rm walk. find -exec rm -rf would otherwise recurse
    # into a live /proc and EPERM-cascade on every /proc/<pid>/ entry
    # — observed on cache-cold rebuilds of the nvidia sysext.
    local mp
    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        [ "$mp" = "$buildroot" ] && continue
        umount -l "$mp" 2>/dev/null || true
    done < <(findmnt -rn -o TARGET --submounts "$buildroot" 2>/dev/null | sort -r)

    # Defence in depth: exclude top-level mount-point dirs in the find
    # itself. If a mount survived the unmount loop (rootless can lose
    # CAP_SYS_ADMIN in some sandbox configurations), `rm -rf` will skip
    # over them entirely instead of EPERM-cascading.
    find "$buildroot" -mindepth 1 -maxdepth 1 \
        ! -name usr ! -name opt \
        ! -name proc ! -name sys ! -name dev ! -name run ! -name tmp \
        -exec rm -rf {} +
    # And drop the mount-point dirs themselves (now guaranteed empty
    # since unmount succeeded or they never had content).
    for mp in proc sys dev run tmp; do
        rmdir "$buildroot/$mp" 2>/dev/null || true
    done

    # /usr/share/glib-2.0/schemas/gschemas.compiled is the binary gvdb
    # cache glib reads at runtime to resolve GSettings schemas. Any
    # sysext that transitively pulls glib2 + a schema-shipping package
    # (libvirt, gvfs, polkit-gnome, ...) triggers glib2's RPM scriptlet
    # which writes a cache covering ONLY the schemas in that sysext's
    # build chroot. Once sysexts overlay /usr, the topmost layer's
    # cache shadows every other layer's — and since each cache is a
    # partial view of a different chroot, whichever one happens to win
    # has nothing to do with what the running apps need. Empirical
    # failure on externy: nvidia's 48KB cache (no nm-applet schemas)
    # sat above desktop's 55KB cache (has them), so nm-applet bailed
    # with "Settings schema 'org.gnome.nm-applet' is not installed".
    #
    # Fix: strip the cache from every sysext, unconditionally. The XML
    # schemas (.gschema.xml) still merge via overlay union. A boot-time
    # service (myosi-glib-schemas-compile.service) then runs
    # glib-compile-schemas across the merged XML dir and writes a fresh
    # union cache to /run/myosi/glib-schemas/glib-2.0/schemas/. The env
    # drop-in /usr/lib/environment.d/40-myosi-glib-schemas.conf points
    # GSETTINGS_SCHEMA_DIR at that runtime union before glib falls
    # through to the base image cache. Generic to any future sysext set
    # — gaming, dev, whatever — without per-sysext opt-ins.
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

# Unit activation in sysexts/profiles is DECLARATIVE only — ship static
# `.wants/` symlinks under each profile's
# mkosi.extra/usr/lib/systemd/{system,user}/<target>.wants/<unit>
# instead of generating them in postinst at build time. Same artifact
# covers BOTH delivery modes (profile baked into main image AND sysext
# merged on the host at runtime); preset-shipped /etc symlinks die in
# strip_to_sysext_layout but /usr/lib/.../.wants/ symlinks survive.
#
# The former sysext_{enable,uphold}_{system,user}_units helpers
# (imperative ln -sf / Upholds= drop-in generators) were removed in
# favour of this single mechanism. See mkosi.extra/usr/lib/systemd/
# system-preset/50-myosi.preset for the full per-tier activation policy
# documentation.

# Fleet-wide guard: no sysext payload should ever ship the dnf package
# manager. Sysexts are sealed verity-protected /usr — no in-place
# upgrades — so dnf at runtime is dead weight (~30 MiB of dnf5,
# dnf5-plugins, libdnf5, libsolv, librepo, python deps). Some sysexts
# (desktop, virt) need dnf at BUILD time inside the buildroot for
# RPMFusion swaps or transitive python pulls.
#
# Not done via mkosi RemovePackages= because:
#   1. dnf5 is listed in /etc/dnf/protected.d/dnf5.conf — `dnf remove
#      dnf5` refuses with "protected packages" and exits non-zero.
#   2. mkosi v26 errors when RemovePackages= names a package that was
#      never installed (No packages to remove for argument: ...).
#
# Use rpm -e --nodeps --noscripts directly to bypass both: rpm doesn't
# consult dnf's protected list and tolerates a missing package set
# cleanly with `|| true`. We also drop /etc/dnf/protected.d so any
# downstream dnf invocation (extremely rare in a sealed sysext) doesn't
# re-trip the protection.
#
# Idempotent: every sysext gets this call via sysext_finalize, but the
# rpm query no-ops on sysexts that never installed dnf5 in the first
# place (firmware, containers, nvidia*, zfs).
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

# Compute the canonical path of a sysext's extension-release file
# inside BUILDROOT. Filename is versioned
# (extension-release.<name>_<image-version>) to match what mkosi v26's
# configure_extension_release() expects to read/write at finalize: if
# the file is already present at that exact path, mkosi parses its
# key=value entries, augments missing required fields (ID, SYSEXT_ID,
# SYSEXT_VERSION_ID, SYSEXT_LEVEL), and writes back the same path. No
# sibling file is generated, no rename is needed afterwards.
#
# Why the version belongs in the filename: when two versions of the
# same sysext sit in /var/lib/extensions/ (current + last-good for
# rollback), each ships its own extension-release.<name>_<ver>.
# Filenames are distinct in the merged overlay so BOTH stay visible;
# systemd-sysext walks the directory, parses IMAGE_ID from the part
# before `_`, groups by ID, picks the highest VERSION per group, and
# merges only one. An unversioned filename would collapse the two
# layers via overlayfs highest-lowerdir-wins (random picker), or — if
# we shipped both unversioned + versioned siblings per payload — make
# sysext see them as distinct extensions and over-merge.
# Architecture token mirrors mkosi's %a specifier (x86-64, arm64, ...).
# Falls back to the host's `uname -m` mapped to mkosi's space for adhoc
# smoke runs where mkosi hasn't exported ARCHITECTURE= yet. Used by both
# the path computation below and by the ARCHITECTURE= line inside the
# extension-release file so every sub-image's release record matches
# the .raw filename's %a token.
sysext_arch() {
    if [ -n "${ARCHITECTURE:-${MKOSI_ARCHITECTURE:-}}" ]; then
        printf '%s' "${ARCHITECTURE:-${MKOSI_ARCHITECTURE}}"
        return 0
    fi
    uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/'
}

# Canonical path = exactly what mkosi v26 expects for a sysext built
# with Output=%i_%v_%a. systemd-sysext reads
# extension-release.<imageid>_<imageversion>_<arch> to validate that
# the merged extension matches the booted host. mkosi's
# configure_extension_release() writes its augmented file at that exact
# path during finalize; if we land OUR file there first, mkosi's pass
# augments missing fields in-place and our extras
# (EXTENSION_RELOAD_MANAGER=1, SYSEXT_KERNEL_RELEASE=<KVER>, ...) survive.
#
# Previously this path was extension-release.<name>_<version> (no arch
# suffix) — a leftover from before mkosi's %a token landed in the
# build. mkosi then wrote its OWN arch-suffixed file alongside ours.
# systemd read mkosi's file (matches the .raw filename), our
# directives never reached the kernel, and Upholds=/EXTENSION_RELOAD_
# MANAGER drop-ins inside the sysext were silently ignored at merge
# time.
sysext_extension_release_path() {
    local buildroot="${BUILDROOT:?BUILDROOT must be set by mkosi}"
    local name="${1:?sysext name required}"
    local version="${IMAGE_VERSION:-dev}"
    local arch
    arch="$(sysext_arch)"
    printf '%s/usr/lib/extension-release.d/extension-release.%s_%s_%s\n' \
        "$buildroot" "$name" "$version" "$arch"
}

# Write the extension-release file for the current sysext directly at
# the versioned path mkosi v26 will pick up. Single source of truth:
# every sysext in the fleet calls this once, with the same shared
# envelope below + optional per-sysext extras passed as KEY=VALUE
# args (e.g. SYSEXT_KERNEL_RELEASE=$KVER for kmod-bearing sysexts).
#
# Replaces the older static-placeholder + sed-substitution pattern
# (mkosi.extra/usr/lib/extension-release.d/extension-release.<name>
# stub with __VERSION__ and __KVER__ markers patched by postinst)
# and the after-the-fact rename pass that consolidated the
# unversioned filename to the versioned one. Both gone — the
# postinst writes the final file with the final values at the
# final filename in one shot.
#
# Args:
#   $1: SYSEXT_ID — also the filename stem (e.g. "nvidia", "containers")
#   $@: extra "KEY=VALUE" lines appended verbatim
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
        # Always set EXTENSION_RELOAD_MANAGER=1. systemd-sysext reads
        # this off the active extension-release files and, when set on
        # any merged extension, issues ONE org.freedesktop.systemd1.
        # Manager.Reload() bus call at the end of the merge batch.
        # That reload is what makes multi-user.target re-parse the
        # sysext-shipped Upholds= drop-ins (50-myosi-{desktop,nvidia,
        # virt}.conf etc.) so units like flatpak-setup.service or
        # nvidia-cdi-refresh.path actually auto-start at first boot.
        # The reload is a no-op for unit-less sysexts since the batch
        # dedupes anyway.
        printf 'EXTENSION_RELOAD_MANAGER=1\n'
        local kv
        for kv in "$@"; do
            printf '%s\n' "$kv"
        done
    } > "$f"
}

# Default close-out for sysext postinst scripts. Usage:
#     sysext_finalize "$@"
# Exits 0 unless mkosi is invoking the `final` stage (mkosi reuses the
# same script for the build-image stage; only the final stage needs
# the policy stage + layout strip).
sysext_finalize() {
    [ "${1:-final}" = "final" ] || exit 0
    strip_buildroot_dnf
    stage_sysext_policy
    strip_to_sysext_layout
}
