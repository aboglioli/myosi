#!/usr/bin/env bash
# OpenZFS sysext build. Sourced by mkosi.images/zfs/mkosi.postinst
# (caller does set -euo pipefail + STAGE guard; BUILDROOT from mkosi).
# Builds upstream GitHub tarball → SRPMs → rpmbuild via kmod_exec; the
# zfsonlinux.org repo lags new Fedora releases by months. On kernels
# upstream doesn't support yet, ZFS_BUILD_OPTIONAL=1 soft-fails to an
# empty stub so CI ships the rest of the release and deployed hosts
# keep their last-good zfs sysext via version precedence.

# Bump on new OpenZFS stable; don't bump past the Linux-Maximum
# declared in upstream's META for our kernel.
ZFS_VERSION="${ZFS_VERSION:-2.4.2}"

KVER=$(ls "$BUILDROOT/usr/lib/modules/" 2>/dev/null | head -1)
[ -n "$KVER" ] || { echo "ERROR: no kernel under $BUILDROOT/usr/lib/modules/" >&2; exit 1; }
echo "Building zfs sysext: zfs=$ZFS_VERSION kver=$KVER"

ZFS_BUILD_OPTIONAL="${ZFS_BUILD_OPTIONAL:-0}"
ZFS_BUILD_BAILOUT=0

bailout_if_optional() {
    local context=$1 status=$2
    if [ "$ZFS_BUILD_OPTIONAL" = "1" ]; then
        echo "WARN: zfs build soft-skip at $context (exit $status); ZFS_BUILD_OPTIONAL=1" >&2
        ZFS_BUILD_BAILOUT=1
        return 0
    fi
    echo "ERROR: zfs build failed at $context (exit $status); set ZFS_BUILD_OPTIONAL=1 to soft-skip" >&2
    exit "$status"
}

# 1. Build deps — matches OpenZFS's documented Fedora set so
#    ./configure enables every feature instead of silently disabling.
#    kernel-devel-${KVER} is what the later cross-kernel rebuild links against.
set +e
dnf5 --installroot="$BUILDROOT" --nogpgcheck install -y \
    akmods gcc gcc-c++ make rpm-build kmod tar gzip \
    autoconf automake libtool \
    "kernel-devel-${KVER}" \
    zlib-ng-compat-devel libuuid-devel libblkid-devel libudev-devel \
    libtirpc-devel openssl-devel libcurl-devel \
    libaio-devel libattr-devel elfutils-libelf-devel libffi-devel \
    python3 python3-devel python3-setuptools python3-cffi python3-packaging \
    pkgconf ncompress
DEPS_STATUS=$?
set -e
if [ "$DEPS_STATUS" -ne 0 ]; then
    bailout_if_optional "build deps install" "$DEPS_STATUS"
fi

# 2. Fetch upstream tarball into the buildroot.
ZFS_SRC_REL=/tmp/zfs-src
ZFS_SRC_ABS="$BUILDROOT$ZFS_SRC_REL"
if [ "$ZFS_BUILD_BAILOUT" -eq 0 ]; then
    mkdir -p "$ZFS_SRC_ABS"
    TARBALL_URL="https://github.com/openzfs/zfs/releases/download/zfs-${ZFS_VERSION}/zfs-${ZFS_VERSION}.tar.gz"
    echo "Fetching $TARBALL_URL"
    set +e
    curl -fsSL --retry 3 --connect-timeout 30 "$TARBALL_URL" \
        -o "$ZFS_SRC_ABS/zfs-${ZFS_VERSION}.tar.gz"
    FETCH_STATUS=$?
    set -e
    if [ "$FETCH_STATUS" -ne 0 ]; then
        bailout_if_optional "tarball fetch" "$FETCH_STATUS"
    fi
fi

# Shared kmod helpers (chroot with real /dev /proc + unmount sweeps) —
# see mkosi.shared/kmod-build.sh.
. "${SRCDIR}/mkosi.shared/kmod-build.sh"

# 3. Extract + configure + make srpm-utils srpm-kmod, all in one sh -c
#    so configure's state persists. autogen.sh is a no-op safety net.
#    SRPMs (not `make rpm`) so the later `rpmbuild --rebuild --define
#    "kernels $KVER"` cross-builds against the buildroot's kernel, not
#    the host's.
if [ "$ZFS_BUILD_BAILOUT" -eq 0 ]; then
    set +e
    kmod_exec sh -c "
        set -e
        cd $ZFS_SRC_REL
        tar xzf zfs-${ZFS_VERSION}.tar.gz
        cd zfs-${ZFS_VERSION}
        ./autogen.sh
        ./configure --with-linux=/usr/src/kernels/$KVER \
                    --with-linux-obj=/usr/src/kernels/$KVER
        make -j\$(nproc) srpm-utils
        make -j\$(nproc) srpm-kmod
        mkdir -p ../SRPMS
        cp -v *.src.rpm ../SRPMS/
    "
    SRPM_STATUS=$?
    set -e
    if [ "$SRPM_STATUS" -ne 0 ]; then
        bailout_if_optional "srpm build" "$SRPM_STATUS"
    fi
fi

# 4. rpmbuild --rebuild the userspace + kmod SRPMs.
BUILDDIR_REL=$ZFS_SRC_REL/rpmbuild
BUILDDIR_ABS="$BUILDROOT$BUILDDIR_REL"
mkdir -p "$BUILDDIR_ABS"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

if [ "$ZFS_BUILD_BAILOUT" -eq 0 ]; then
    USR_SRPM=$(find "$BUILDROOT$ZFS_SRC_REL/SRPMS" -maxdepth 1 -name 'zfs-*.src.rpm' \
              -not -name 'zfs-kmod-*' | head -1)
    KMOD_SRPM=$(find "$BUILDROOT$ZFS_SRC_REL/SRPMS" -maxdepth 1 -name 'zfs-kmod-*.src.rpm' | head -1)
    [ -n "$USR_SRPM" ]  || { echo "ERROR: userspace SRPM not produced" >&2; exit 1; }
    [ -n "$KMOD_SRPM" ] || { echo "ERROR: kmod SRPM not produced" >&2; exit 1; }
    echo "Userspace SRPM: ${USR_SRPM#$BUILDROOT}"
    echo "Kmod SRPM:      ${KMOD_SRPM#$BUILDROOT}"

    set +e
    kmod_exec rpmbuild --rebuild \
        --define "_topdir $BUILDDIR_REL" \
        --define "kernels $KVER" \
        --target x86_64 \
        "${KMOD_SRPM#$BUILDROOT}"
    KMOD_STATUS=$?
    set -e
    if [ "$KMOD_STATUS" -ne 0 ]; then
        bailout_if_optional "kmod rpmbuild" "$KMOD_STATUS"
    fi
fi

if [ "$ZFS_BUILD_BAILOUT" -eq 0 ]; then
    set +e
    kmod_exec rpmbuild --rebuild \
        --define "_topdir $BUILDDIR_REL" \
        --target x86_64 \
        "${USR_SRPM#$BUILDROOT}"
    USR_STATUS=$?
    set -e
    if [ "$USR_STATUS" -ne 0 ]; then
        bailout_if_optional "userspace rpmbuild" "$USR_STATUS"
    fi
fi

# On bailout ship an empty, kernel-pinned stub; operators keep their
# last-good zfs sysext via version precedence.
if [ "$ZFS_BUILD_BAILOUT" -eq 1 ]; then
    rm -rf "$BUILDROOT$ZFS_SRC_REL"
    kmod_unmount
    kmod_unmount_all_under "$BUILDROOT"
    kmod_ship_empty_stub zfs "zfs=$ZFS_VERSION incompatible with kernel $KVER"
    return 0
fi

# 5. Install built RPMs in a SINGLE dnf transaction: userspace zfs
#    requires `zfs-kmod = ${ZFS_VERSION}`, which dnf can't resolve
#    across two separate --installroot calls. Select the kernel-
#    suffixed binary kmod; exclude meta/devel/debug siblings.
RUNTIME_RPMS=$(find "$BUILDDIR_ABS/RPMS" -name '*.rpm' \
    -not -name '*debug*' -not -name '*-devel-*' -not -name '*-test-*' \
    -not -name '*src.rpm' \
    \( -name "kmod-zfs-${KVER}-*.rpm" \
       -o \( -not -name 'kmod-*' \) \))

[ -n "$RUNTIME_RPMS" ] || { echo "ERROR: no runtime RPMs to install" >&2; exit 1; }
if ! echo "$RUNTIME_RPMS" | grep -q "kmod-zfs-${KVER}-"; then
    echo "ERROR: binary kmod-zfs-${KVER}-*.rpm not in selection" >&2
    find "$BUILDDIR_ABS/RPMS" -name 'kmod-*.rpm' | head >&2
    exit 1
fi

echo "Installing runtime RPMs:"
echo "$RUNTIME_RPMS" | sed "s|$BUILDROOT||"
dnf5 --installroot="$BUILDROOT" --nogpgcheck install -y $RUNTIME_RPMS

# 6. depmod inside the buildroot.
kmod_exec depmod -a "$KVER"

# 7. Sign ZFS/SPL modules with boot.key (see kmod-build.sh).
kmod_sign_modules zfs -path '*/extra/*' \
    \( -name 'zfs*.ko*' -o -name 'spl.ko*' -o -name 'zcommon.ko*' \
    -o -name 'znvpair.ko*' -o -name 'zlua.ko*' -o -name 'zunicode.ko*' \
    -o -name 'zzstd.ko*' -o -name 'icp.ko*' \)

# 8. Strip build artifacts + dev packages before sealing. Same dance
#    as nvidia: unmount before dnf5 remove, sweep again after.
rm -rf "$BUILDROOT$ZFS_SRC_REL"
kmod_unmount

dnf5 --installroot="$BUILDROOT" remove -y \
    akmods rpm-build gcc gcc-c++ make autoconf automake libtool tar gzip \
    "kernel-devel-${KVER}" \
    zlib-ng-compat-devel libuuid-devel libblkid-devel libudev-devel \
    libtirpc-devel openssl-devel libcurl-devel \
    libaio-devel libattr-devel elfutils-libelf-devel libffi-devel \
    python3-devel python3-setuptools python3-cffi python3-packaging \
    pkgconf ncompress 2>/dev/null || true

kmod_unmount_all_under "$BUILDROOT"

# 8b. Re-run depmod + assert zfs.ko is indexed (see kmod-build.sh).
kmod_depmod_after_strip
kmod_mark_indices_unique zfs

if ! kmod_indexed "extra/zfs/zfs.ko"; then
    echo "ERROR: zfs.ko not indexed in modules.dep after depmod." >&2
    echo "       /usr/lib/modules/$KVER/ contents:" >&2
    ls -la "$BUILDROOT/usr/lib/modules/$KVER/" >&2 || true
    exit 1
fi

# 9. Extension-release: shared envelope + kernel pin.
. "${SRCDIR}/mkosi.shared/sysext-build.sh"
sysext_write_extension_release zfs \
    "SYSEXT_KERNEL_RELEASE=${KVER}"

# 10. Finalize sysext.
sysext_finalize

echo "zfs sysext build complete: zfs=$ZFS_VERSION kver=$KVER"
