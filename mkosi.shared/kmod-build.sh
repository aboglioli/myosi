#!/usr/bin/env bash
# Shared helpers for out-of-tree kernel module sysext builds (NVIDIA,
# future ZFS / WireGuard / VirtualBox / ...). Source from a sysext
# postinst:
#
#     . "${SRCDIR}/mkosi.shared/kmod-build.sh"
#     kmod_exec rpmbuild --rebuild ...
#     kmod_exec depmod -a "$KVER"
#
# Why bind-mount /dev /proc /sys around `chroot $BUILDROOT cmd`:
#   Out-of-tree kmod source RPMs (NVIDIA's nvidia-kmod, OpenZFS's
#   zfs-kmod, etc.) ship a `conftest` step that runs gcc against
#   generated probe stubs and captures stderr. A plain `chroot` into
#   $BUILDROOT does NOT propagate /dev (real char devices), /proc, or
#   /sys, so conftest's `gcc … 2> /dev/null` and similar redirections
#   land on stub files or fail silently — the resulting macros.h gets
#   filled with stray gcc error output and every subsequent compile
#   step blows up with bogus `unknown type name 'va_list'` /
#   `implicit declaration of dma_is_direct` cascades that look like
#   source incompatibilities but are pure build-env breakage.
#
#   `systemd-nspawn` would handle this automatically but is not on
#   PATH inside the mkosi postinst sandbox (mkosi v26 strips it from
#   the build sandbox even when systemd-container is installed in the
#   host). Plain bind-mount + chroot works regardless of sandbox.
#
# The trap ensures mounts are unwound on any exit path — leftover
# binds would let mkfs.erofs walk into the host filesystem and bake
# arbitrary contents into the sealed sysext.

# Stack of buildroots that need cleanup. Each kmod_exec call appends
# itself if it had to set up the mounts; the trap unmounts in reverse.
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

# Aggressive cleanup: walks `findmnt` and unmounts every mount whose
# target is under $BUILDROOT, regardless of who set it up. Use as the
# final step before sysext sealing — dnf5 transactions silently
# re-mount /proc + /dev into the installroot to run rpm scriptlets,
# and those re-mounts outlive the dnf5 process. Without this step,
# `strip_to_sysext_layout` (or any rm walk of the buildroot) ends up
# operating on live /proc inodes and hits EPERM cascades.
kmod_unmount_all_under() {
    local target=$1
    # Canonicalize so the equality check matches findmnt's normalized
    # TARGET column regardless of trailing slashes or symlink resolution.
    local target_real
    target_real=$(readlink -f "$target") || target_real=$target
    # Reverse-order to handle nested mounts. NEVER unmount the target
    # itself — that is the buildroot bind mkosi set up around our
    # postinst, and dropping it disintegrates the rest of the build.
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
        # mkosi's postinst sandbox masks /sys entirely (and may mask
        # /proc on some hosts). Skip whatever the host doesn't expose
        # — the conftest probes that need a real /dev/null still get
        # one, which is what fixed the NVIDIA build empirically.
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

# ---------------------------------------------------------------------
# Helpers below are pure-host (no chroot, no bind-mounts). They run
# AFTER the per-kmod build/install/dnf-remove sequence and consolidate
# the boilerplate that's identical across nvidia-build.sh and
# zfs-build.sh — and will be identical across future kmod sysexts
# (WireGuard, VirtualBox, openzfs-rc, etc.). Keep this section
# strictly kmod-payload-shaping logic; sysext-shape concerns
# (extension-release, finalize, strip) belong in sysext-build.sh.
# ---------------------------------------------------------------------

# Sign every kernel module under $BUILDROOT/usr/lib/modules/$KVER/
# that matches the given `find` predicate args, using boot.key from
# keys/ as the module signing key.
#
# Why the kmod-signing step needs to be inside the sysext build (not
# left to the host): the base UKI cmdline carries
# `module.sig_enforce=1`, so the kernel refuses to load any module
# whose appended PKCS#7 signature doesn't verify against a key in the
# `.platform` keyring (UEFI db) or `.machine` keyring (MOK). Without
# this step the .ko files ship fine but every modprobe fails with
# "Loading of unsigned module is rejected" / "module verification
# failed", and the device never binds.
#
# F44's kernel ships zstd-compressed modules (.ko.zst). sign-file
# operates on raw ELF, so we decompress in place, sign, then recompress
# under the same filename — the appended signature sits at the end of
# the ELF and survives the zstd / xz round-trip. .ko (uncompressed)
# and .ko.xz are also handled in case a kmod rebuild emits them.
#
# CRITICAL: the recompress step for .ko.xz MUST use the same xz options
# Fedora's brp-strip-kmod ships with stock kernel modules — single
# block, 1 MiB LZMA2 dictionary, CRC32 check. The kernel's xz_dec
# decompressor uses single-call mode with a constrained dictionary
# buffer; a default `xz -f file` produces multi-block 8 MiB-dict CRC64
# streams that decompress fine with userspace xz BUT fail in-kernel
# with XZ_BUF_ERROR (status 6 — "Cannot make any progress"), printed
# as `decompression failed with status 6` followed by `modprobe:
# ERROR: could not insert '<mod>': Invalid argument`. The .ko.xz still
# unpacks correctly on the host, so this bug was invisible at build
# time — only modprobe on the deployed host catches it.
#
# Args:
#   $1: log tag (`nvidia`, `zfs`, ...). Echoed in the "Signed N <tag>
#       modules" summary at the end.
#   $@: passed verbatim to find as the predicate after
#       `find $BUILDROOT/usr/lib/modules/$KVER`. Pick whatever isolates
#       the modules you want to sign, e.g.
#         -name 'nvidia*.ko*'
#         -path '*/extra/*' \( -name 'zfs*.ko*' -o -name 'spl.ko*' \)
#
# Exits non-zero if no modules matched (caller almost always wants
# this — an empty sign pass means the install step lost the kmod).
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
                # See header comment for the kernel xz_dec rationale.
                #   --lzma2=dict=1MiB  match Fedora's stock kmod dict size
                #   --check=crc32      match Fedora's stock kmod checksum
                #   --threads=1        force single-block stream. xz's
                #                      default multi-threaded mode splits
                #                      large files into N blocks (1 per
                #                      thread); kernel xz_dec single-call
                #                      mode (`xz_dec_run`) cannot stream
                #                      across block boundaries when the
                #                      output buffer is sized for one
                #                      block, and fails with
                #                      XZ_BUF_ERROR mid-decompression.
                #                      Empirically confirmed against a
                #                      9.5 MiB nvidia.ko.xz: default xz
                #                      produced 9 blocks; --threads=1
                #                      produces 1 block (matches stock
                #                      Fedora kmod layout).
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

# Re-run depmod against the buildroot after the post-build dnf remove
# transaction. Belt-and-suspenders against two failure modes seen on
# 2026.06.05.01 and 2026.06.05.03 releases:
#
#   1. The dnf remove strips the filesystem RPM that owns the
#      `/lib -> usr/lib` compat symlink. depmod -b BASEDIR writes via
#      `<BASEDIR>/lib/modules/<kver>/`. With /lib missing depmod
#      creates a real /lib/modules/ tree which then gets wiped by
#      sysext_finalize's `! -name usr ! -name opt` strip filter.
#   2. The first kmod_exec depmod -a (run earlier with kernel-devel +
#      akmods still installed) wrote a valid modules.dep — the dnf
#      remove transaction's rpm scriptlets then deleted it.
#
# This helper restores the symlink if missing, re-runs depmod, and
# mirrors any /lib/modules/<kver>/ output back into the canonical
# /usr/lib/modules/<kver>/ path so the sealed payload always has the
# index regardless of which fallback path depmod took.
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

# No-op. Kept as a stub so existing postinst callers continue to work
# while we phase the call out.
#
# Originally tried to defeat mkosi v26's de-duplicator by prepending a
# `# myosi <tag> sysext` comment to modules.{dep,alias,softdep,symbols,
# devname}. That assumed mkosi did content-hash dedup. It does NOT: the
# logic at mkosi/__init__.py mount_base_trees() strips any overlay path
# that exists in the base-tree REGARDLESS of content
# ("Removing duplicate path /{rel} from overlay" + unlink). Verified on
# the 2026.06.06.02 nvidia sysext — `systemd-dissect --mtree` showed
# .ko files at extra/nvidia/ but no modules.dep at all.
#
# The host-side fix is in myosi-depmod.service: it stacks a tmpfs
# overlay on /usr/lib/modules/<KVER>/ and runs `depmod -a` so the
# effective modules.dep includes the merged sysext extras. The
# build-side tries to ship modules.{dep,alias,...} now goes nowhere —
# this helper just stays as a stub so removing the call from
# postinsts isn't a coordinated change.
kmod_mark_indices_unique() {
    :
}

# Assert that modules.dep references the given module path so the
# build refuses to ship a sysext where the index lost its kmod
# entries. Catches the regression at build time instead of after
# release + reboot.
#
# Args:
#   $1: ko path fragment to grep for, e.g. `extra/nvidia/nvidia.ko` or
#       `extra/zfs/zfs.ko`. Dots are passed literally to grep -F.
#
# Returns 0 if found, 1 if missing (caller decides whether to exit or
# fall back to ship_empty_stub).
kmod_indexed() {
    local pat=$1
    grep -Fq "$pat" \
        "$BUILDROOT/usr/lib/modules/$KVER/modules.dep" 2>/dev/null
}

# Ship an empty sysext payload when the kmod build cannot complete
# against the current kernel — for example a legacy proprietary
# driver branch on a kernel newer than the vendor's support window.
# Operators keep their last-good sysext via systemd-sysext's version
# precedence (highest SYSEXT_VERSION_ID per IMAGE_ID wins) and a
# clean release pipeline ships a stub instead of failing the whole
# build.
#
# Wipes /usr/lib/modules from the buildroot, sources sysext-build.sh
# for the finalize helpers, writes a kernel-pinned extension-release
# (so it still won't merge on the wrong kernel) and seals. Caller is
# expected to exit 0 right after this returns.
#
# Args:
#   $1: sysext name (drives SYSEXT_ID + filename — `nvidia`,
#       `nvidia-580xx`, `zfs`, ...).
#   $2: short reason for the log line.
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
