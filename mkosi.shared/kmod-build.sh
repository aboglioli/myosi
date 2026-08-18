#!/usr/bin/env bash
# Shared helpers for out-of-tree kmod sysext builds (NVIDIA, ZFS, ...).
# kmod_exec bind-mounts /dev /proc /sys around `chroot $BUILDROOT`:
# kmod conftest steps redirect gcc stderr to /dev/null, and a bare
# chroot gives them stub files — generated headers fill with gcc noise
# and compiles fail with bogus va_list/dma_is_direct errors.
# systemd-nspawn is not on PATH in the mkosi v26 postinst sandbox.
# The trap unwinds mounts on any exit — leftover binds would let
# mkfs.erofs bake host filesystem contents into the sealed sysext.

# Buildroots needing cleanup; the trap unmounts in reverse.
declare -ga __KMOD_MOUNTED_ROOTS=()

__kmod_cleanup() {
    local root m
    for root in "${__KMOD_MOUNTED_ROOTS[@]}"; do
        for m in sys proc dev; do
            if mountpoint -q "$root/$m"; then
                umount -lR "$root/$m" || true
            fi
        done
    done
    __KMOD_MOUNTED_ROOTS=()
}

# Unmount everything under $BUILDROOT regardless of who mounted it.
# Final step before sealing: dnf5 rpm scriptlets re-mount /proc + /dev
# into the installroot and leave them; rm walks would then hit live
# /proc inodes and EPERM-cascade.
kmod_unmount_all_under() {
    local target=$1
    # Canonicalize to match findmnt's normalized TARGET column.
    local target_real
    target_real=$(readlink -f "$target") || target_real=$target
    # Reverse order for nested mounts. NEVER unmount the target itself —
    # that's mkosi's buildroot bind; dropping it kills the build.
    local mp
    while IFS= read -r mp; do
        [ -n "$mp" ] || continue
        [ "$mp" = "$target_real" ] && continue
        [ "$mp" = "$target" ] && continue
        umount -l "$mp" 2>/dev/null || true
    done < <(findmnt -rn -o TARGET --submounts "$target" 2>/dev/null | sort -r)
    # Also clean explicit /dev /proc /sys binds we set up
    __kmod_cleanup
}
trap __kmod_cleanup EXIT INT TERM

__kmod_setup() {
    local root=$1
    local m mounted=0
    for m in dev proc sys; do
        # mkosi's sandbox masks /sys (sometimes /proc). Skip what the
        # host lacks — a real /dev/null is what conftest actually needs.
        [ -d "/$m" ] || { echo "kmod_exec: host has no /$m; skipping bind-mount" >&2; continue; }
        mkdir -p "$root/$m"
        if ! mountpoint -q "$root/$m"; then
            mount --rbind "/$m" "$root/$m"
            mount --make-rslave "$root/$m" 2>/dev/null || true
            mounted=1
        fi
    done
    if [ "$mounted" -eq 1 ]; then
        # Avoid duplicates if already tracked
        local r seen=0
        for r in "${__KMOD_MOUNTED_ROOTS[@]}"; do
            [ "$r" = "$root" ] && seen=1
        done
        [ "$seen" -eq 0 ] && __KMOD_MOUNTED_ROOTS+=("$root")
    fi
}

# Run a command inside the buildroot with real /dev /proc /sys.
kmod_exec() {
    __kmod_setup "$BUILDROOT"
    chroot "$BUILDROOT" "$@"
}

# Tear down mounts explicitly (call before sysext sealing so mkfs.erofs
# doesn't walk into bind-mounted host filesystems).
kmod_unmount() {
    __kmod_cleanup
}

# --- Pure-host helpers (no chroot/binds), shared across kmod sysexts.
# Keep strictly kmod-payload-shaping; sysext-shape concerns belong in
# sysext-build.sh.

# Sign modules under $BUILDROOT/usr/lib/modules/$KVER matching the find
# predicate ($2...) with keys/boot.key; $1 is a log tag. Required: the
# UKI carries module.sig_enforce=1, so unsigned modules are refused at
# modprobe. Compressed modules are decompressed, signed, recompressed —
# the appended signature survives the round-trip.
# CRITICAL for .ko.xz: recompress with Fedora's stock kmod options
# (single block, 1 MiB dict, CRC32). Default xz emits multi-block CRC64
# streams that userspace unpacks fine but the in-kernel xz_dec fails
# with XZ_BUF_ERROR → modprobe "Invalid argument"; invisible at build
# time, only the deployed host catches it.
# Exits non-zero if nothing matched (empty sign pass = lost kmod).
kmod_sign_modules() {
    local tag=$1
    shift
    local sign_file=/usr/src/kernels/$KVER/scripts/sign-file
    local stage=$BUILDROOT/tmp/sign
    mkdir -p "$stage"
    install -m 0600 "${SRCDIR}/keys/boot.key" "$stage/boot.key"
    install -m 0644 "${SRCDIR}/keys/boot.crt" "$stage/boot.crt"

    local signed=0 ko rel
    while IFS= read -r -d '' ko; do
        rel="${ko#$BUILDROOT}"
        case "$ko" in
            *.ko.zst)
                kmod_exec sh -c "
                    zstd -q -d -f '$rel' -o '$rel.unsigned' &&
                    '$sign_file' sha256 /tmp/sign/boot.key /tmp/sign/boot.crt '$rel.unsigned' &&
                    zstd -q -f --rm '$rel.unsigned' -o '$rel'
                "
                ;;
            *.ko.xz)
                # Options must match Fedora's stock kmod layout (see
                # function header): --threads=1 forces a single-block
                # stream — kernel xz_dec can't cross block boundaries.
                kmod_exec sh -c "
                    xz -q -d -k -f '$rel' &&
                    '$sign_file' sha256 /tmp/sign/boot.key /tmp/sign/boot.crt '${rel%.xz}' &&
                    xz -q -f --lzma2=dict=1MiB --check=crc32 --threads=1 '${rel%.xz}'
                "
                ;;
            *.ko)
                kmod_exec "$sign_file" sha256 \
                    /tmp/sign/boot.key /tmp/sign/boot.crt "$rel"
                ;;
            *)
                continue
                ;;
        esac
        signed=$((signed + 1))
    done < <(find "$BUILDROOT/usr/lib/modules/$KVER" "$@" -print0)
    rm -rf "$stage"

    echo "Signed $signed $tag modules with boot.key"
    [ "$signed" -gt 0 ] || {
        echo "ERROR: no $tag modules matched signing predicate" >&2
        return 1
    }
}

# Re-run depmod after the dnf remove: (1) the remove can strip the
# /lib → usr/lib compat symlink, making depmod write a real /lib tree
# that the sysext strip wipes; (2) rpm scriptlets delete the earlier
# modules.dep. Restores the symlink, re-runs depmod, mirrors any /lib
# output back into /usr/lib/modules/<kver>/.
kmod_depmod_after_strip() {
    [ -e "$BUILDROOT/lib" ] || ln -sfn usr/lib "$BUILDROOT/lib"
    depmod -b "$BUILDROOT" "$KVER"
    if [ -d "$BUILDROOT/lib/modules/$KVER" ] && \
       [ ! -L "$BUILDROOT/lib" ]; then
        mkdir -p "$BUILDROOT/usr/lib/modules/$KVER"
        cp -a "$BUILDROOT/lib/modules/$KVER/." \
              "$BUILDROOT/usr/lib/modules/$KVER/"
    fi
}

# No-op stub kept so callers keep working. Shipping modules.dep in a
# sysext is futile: mkosi v26 mount_base_trees() strips any overlay
# path that exists in the base-tree regardless of content. The host-
# side fix is /usr/libexec/myosi/sysext-modules-refresh (tmpfs overlay +
# depmod -a), run as systemd-sysext.service ExecStartPost.
kmod_mark_indices_unique() {
    :
}

# Assert modules.dep references the given ko path fragment ($1, e.g.
# `extra/nvidia/nvidia.ko`) so a sysext with a lost index fails at
# build time, not after release + reboot. Returns 0/1.
kmod_indexed() {
    local pat=$1
    grep -Fq "$pat" \
        "$BUILDROOT/usr/lib/modules/$KVER/modules.dep" 2>/dev/null
}

# Ship an empty sysext payload ($1 = name, $2 = reason) when the kmod
# can't build against the current kernel: wipes /usr/lib/modules,
# writes a kernel-pinned extension-release, seals. Deployed hosts keep
# their last-good sysext via version precedence. Caller exits 0 after.
kmod_ship_empty_stub() {
    local name=$1
    local reason=${2:-incompatible}
    rm -rf "$BUILDROOT/usr/lib/modules"
    . "${SRCDIR}/mkosi.shared/sysext-build.sh"
    sysext_write_extension_release "$name" \
        "SYSEXT_KERNEL_RELEASE=${KVER}"
    sysext_finalize
    echo "$name sysext SKIPPED ($reason; kver=$KVER)"
}
