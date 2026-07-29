#!/usr/bin/env bash
# NVIDIA sysext build. Sourced by mkosi.images/nvidia/mkosi.postinst
# (NVIDIA_BRANCH=current — Turing+, open kmod) and nvidia-580xx
# (Maxwell/Pascal/Volta, proprietary). Caller must set -euo pipefail,
# guard STAGE, and export NVIDIA_BRANCH; BUILDROOT comes from mkosi.
# akmods CLI needs runuser (setuid — fails in rootless builds), so we
# drive rpmbuild ourselves inside the chroot.

case "${NVIDIA_BRANCH:?must be set by caller (current or 580xx)}" in
    current)
        PKG_SUFFIX=""
        KMOD_NAME="nvidia"
        SRPM_PATH="/usr/src/akmods/nvidia-kmod.latest"
        # Open kernel modules: force kmod_nvidia_open branch in the spec.
        # Turing+ GPUs only — Pascal/Maxwell/Volta need 580xx.
        RPMBUILD_DEFINE="_with_kmod_nvidia_open 1"
        # GSP firmware present on Turing+
        GPU_FIRMWARE=1
        # Open variant is dual-licensed
        LICENSE_EXPECTED="Dual MIT/GPL"
        LICENSE_ON_MISMATCH="warn"
        EXT_REL_NAME="nvidia"
        ;;
    580xx)
        PKG_SUFFIX="-580xx"
        KMOD_NAME="nvidia-580xx"
        SRPM_PATH="/usr/src/akmods/nvidia-580xx-kmod.latest"
        # Bypass the lspci-based detect branch (no GPU in build container
        # → would incorrectly pick open modules, which don't bind on Pascal).
        RPMBUILD_DEFINE="_without_kmod_nvidia_detect 1"
        # No GSP on legacy GPUs
        GPU_FIRMWARE=0
        # Proprietary expected; reject if it built as open
        LICENSE_EXPECTED="proprietary"
        LICENSE_ON_MISMATCH="error"
        EXT_REL_NAME="nvidia-580xx"
        ;;
    *)
        echo "ERROR: unknown NVIDIA_BRANCH='$NVIDIA_BRANCH' (expected: current|580xx)" >&2
        exit 1
        ;;
esac

KVER=$(ls "$BUILDROOT/usr/lib/modules/" 2>/dev/null | head -1)
[ -n "$KVER" ] || { echo "ERROR: no kernel under $BUILDROOT/usr/lib/modules/" >&2; exit 1; }
echo "Building nvidia${PKG_SUFFIX} sysext: branch=$NVIDIA_BRANCH kver=$KVER"

. "${SRCDIR}/mkosi.shared/sysext-build.sh"

# Build deps + userspace + akmod source. Postinst-run dnf doesn't
# inherit mkosi's sandbox repo dir (only mkosi's own dnf pass does), so
# stage the repos; /etc is stripped before sealing, nothing leaks.
stage_sandbox_repos

dnf5 --installroot="$BUILDROOT" --nogpgcheck install -y \
    akmods gcc gcc-c++ make rpm-build kmod \
    "kernel-devel-${KVER}" \
    "akmod-nvidia${PKG_SUFFIX}" \
    "xorg-x11-drv-nvidia${PKG_SUFFIX}" \
    "xorg-x11-drv-nvidia${PKG_SUFFIX}-libs" \
    "xorg-x11-drv-nvidia${PKG_SUFFIX}-cuda" \
    nvidia-persistenced \
    nvidia-modprobe \
    libva-nvidia-driver \
    egl-wayland

# Separate dnf invocation: rpm's sig check fails on upstream toolkit
# RPMs; %_pkgverify_level none + tsflags=nocrypto scoped to this
# transaction only.
mkdir -p "$BUILDROOT/etc/rpm"
printf '%%_pkgverify_level none\n' > "$BUILDROOT/etc/rpm/macros.verify"
dnf5 --installroot="$BUILDROOT" --nogpgcheck install -y \
    --setopt=tsflags=nocrypto \
    nvidia-container-toolkit
rm -f "$BUILDROOT/etc/rpm/macros.verify"

for unit in nvidia-cdi-refresh.service nvidia-cdi-refresh.path; do
    if [ ! -f "$BUILDROOT/usr/lib/systemd/system/$unit" ] \
       && [ -f "$BUILDROOT/etc/systemd/system/$unit" ]; then
        install -D -m 0644 \
            "$BUILDROOT/etc/systemd/system/$unit" \
            "$BUILDROOT/usr/lib/systemd/system/$unit"
    fi
done

[ -f "$BUILDROOT$SRPM_PATH" ] || { echo "ERROR: $SRPM_PATH not in buildroot" >&2; exit 1; }

# kmod_exec: chroot with real /dev /proc /sys so nvidia-kmod's conftest
# probes work — see kmod-build.sh.
. "${SRCDIR}/mkosi.shared/kmod-build.sh"

# 3. rpmbuild the kmod inside the buildroot.
BUILDDIR_REL=/tmp/nvidia-build
BUILDDIR_ABS="$BUILDROOT$BUILDDIR_REL"
mkdir -p "$BUILDDIR_ABS"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

kmod_exec rpmbuild --rebuild \
    --define "_topdir $BUILDDIR_REL" \
    --define "kernels $KVER" \
    --define "kmod_name $KMOD_NAME" \
    --define "$RPMBUILD_DEFINE" \
    --target x86_64 \
    "$SRPM_PATH"

KMOD_RPM=$(find "$BUILDDIR_ABS/RPMS" -name "kmod-${KMOD_NAME}-*.rpm" -not -name "*debug*" | head -1)
[ -n "$KMOD_RPM" ] || { echo "ERROR: built kmod RPM not found" >&2; exit 1; }
echo "Installing built kmod: ${KMOD_RPM#$BUILDROOT}"
# dnf5 --installroot resolves package paths from the HOST filesystem —
# pass the full host-visible path, no $BUILDROOT strip.
dnf5 --installroot="$BUILDROOT" install -y "$KMOD_RPM"

# 4. depmod inside the buildroot.
kmod_exec depmod -a "$KVER"

# 5. License verification.
NVIDIA_KO=$(find "$BUILDROOT/usr/lib/modules/$KVER" -name 'nvidia.ko*' 2>/dev/null | head -1)
if [ -n "$NVIDIA_KO" ]; then
    LICENSE=$(kmod_exec modinfo -F license "${NVIDIA_KO#$BUILDROOT}" 2>/dev/null || echo "unknown")
    echo "nvidia.ko license=$LICENSE (expected=$LICENSE_EXPECTED)"
    case "$LICENSE_EXPECTED:$LICENSE" in
        "Dual MIT/GPL:Dual MIT/GPL")
            ;;  # OK
        "proprietary:Dual MIT/GPL")
            # Built open when we wanted proprietary — fatal for legacy GPUs.
            echo "ERROR: 580xx legacy expects proprietary, got open ($LICENSE) — will not bind on Pascal" >&2
            exit 1
            ;;
        "Dual MIT/GPL:"*)
            # Wanted open, got something else
            if [ "$LICENSE_ON_MISMATCH" = "error" ]; then
                echo "ERROR: open variant expected, got '$LICENSE'" >&2
                exit 1
            else
                echo "WARN: open module expected but license is $LICENSE" >&2
            fi
            ;;
        "proprietary:"*)
            ;;  # Anything not Dual MIT/GPL = proprietary, OK
    esac
else
    echo "ERROR: nvidia.ko not built" >&2
    exit 1
fi

# 5b. Sign nvidia*.ko with boot.key (module.sig_enforce=1 — see
#     kmod_sign_modules in kmod-build.sh).
kmod_sign_modules "nvidia${PKG_SUFFIX}" -name 'nvidia*.ko*'

# 6a. modprobe.d — module OPTIONS only; nouveau/nova_core blacklist
#     policy lives in the UKI cmdline (mkosi.conf module_blacklist=).
mkdir -p "$BUILDROOT/usr/lib/modprobe.d"
cat > "$BUILDROOT/usr/lib/modprobe.d/50-nvidia.conf" <<EOF
options nvidia_drm modeset=1 fbdev=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_EnableGpuFirmware=$GPU_FIRMWARE
options nvidia NVreg_DynamicPowerManagement=0x02
EOF

# 6b. modules-load.d — nvidia_modeset/nvidia_drm have NO softdep/alias
#     chain; without explicit load the dGPU never enumerates DRM
#     connectors (external outputs dead) and modeset stays disabled.
mkdir -p "$BUILDROOT/usr/lib/modules-load.d"
cat > "$BUILDROOT/usr/lib/modules-load.d/50-nvidia.conf" <<EOF
nvidia
nvidia_modeset
nvidia_drm
EOF

# 7. Strip build artifacts + dev packages before sealing. Order
# matters: drop the bind mounts FIRST — dnf5 aborts a remove
# transaction (exit 32) when the installroot has foreign bind mounts.
rm -rf "$BUILDDIR_ABS"
kmod_unmount

dnf5 --installroot="$BUILDROOT" remove -y \
    akmods rpm-build gcc gcc-c++ make \
    "kernel-devel-${KVER}" 2>/dev/null || true
# rpmfusion-*-release aren't in the remove list — the repo files come
# from mkosi.sandbox; the release RPMs were never installed.

# dnf5 scriptlets leave /proc + /dev mounted in the installroot; sweep
# again or strip_to_sysext_layout hits live /proc inodes (EPERM).
kmod_unmount_all_under "$BUILDROOT"

# 7b. Re-run depmod (dnf remove wiped the earlier index) — see
#     kmod-build.sh.
kmod_depmod_after_strip
kmod_mark_indices_unique "nvidia${PKG_SUFFIX}"

# Refuse to ship without nvidia.ko indexed. NVIDIA_BUILD_OPTIONAL=1
# (legacy branch on a too-new kernel) ships an empty stub instead of
# failing the release; hosts keep their last-good sysext.
if ! kmod_indexed "extra/nvidia/nvidia.ko"; then
    if [ "${NVIDIA_BUILD_OPTIONAL:-0}" = "1" ]; then
        echo "WARN: nvidia.ko not indexed; NVIDIA_BUILD_OPTIONAL=1" >&2
        kmod_ship_empty_stub "$EXT_REL_NAME" \
            "kernel $KVER too new for $NVIDIA_BRANCH driver branch"
        exit 0
    fi
    echo "ERROR: nvidia.ko not indexed in modules.dep after depmod." >&2
    echo "       /usr/lib/modules/$KVER/ contents:" >&2
    ls -la "$BUILDROOT/usr/lib/modules/$KVER/" >&2 || true
    exit 1
fi

# 8. Finalize. Unit activation is declarative: static .wants/ symlinks
#    ship in the sub-image's mkosi.extra (laid down before the rpm
#    install, pointing at units the toolkit package installs).

# 9. Extension-release: shared envelope + kernel pin.
sysext_write_extension_release "$EXT_REL_NAME" \
    "SYSEXT_KERNEL_RELEASE=${KVER}"

sysext_finalize

echo "nvidia${PKG_SUFFIX} sysext build complete: kver=$KVER"
