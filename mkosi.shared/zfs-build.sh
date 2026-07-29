#!/usr/bin/env bash
# Shared OpenZFS sysext build logic. Sourced by
# mkosi.images/zfs/mkosi.postinst.
#
# Caller must:
#   - have already done `set -euo pipefail` and the STAGE != final guard
#   - have BUILDROOT exported (mkosi does this)
#
# Build path — upstream tarball → SRPM → rpmbuild via kmod_exec.
# Does NOT rely on the OpenZFS Fedora repo (zfsonlinux.org/fedora/);
# upstream's repo only goes up to fc42 today and lags new Fedora
# releases by months. By generating SRPMs from the GitHub release
# tarball directly, we ride the same release cadence as OpenZFS's
# stable line — bump $ZFS_VERSION when a new tag drops and rebuild.
#
# Steps:
#   1. Install autotools + gcc + kernel-devel + libraries needed by
#      OpenZFS's ./configure + make srpm-utils srpm-kmod.
#   2. Download zfs-${ZFS_VERSION}.tar.gz from GitHub releases.
#   3. ./configure + make srpm-utils srpm-kmod via kmod_exec — emits
#      zfs-${ZFS_VERSION}-1.fc44.src.rpm (userspace) and
#      zfs-kmod-${ZFS_VERSION}-1.fc44.src.rpm (kmod) under
#      /tmp/zfs-src/SRPMS/ inside the buildroot.
#   4. rpmbuild --rebuild both SRPMs via kmod_exec. RPMS land under
#      /tmp/zfs-src/RPMS/.
#   5. dnf5 install the built RPMs into the installroot.
#   6. depmod + sign every zfs / spl / zcommon / znvpair / zlua /
#      zunicode / zzstd / icp .ko with boot.key.
#   7. Strip build deps + tarball + SRPM/RPMS staging.
#   8. Seal sysext.
#
# Version skew / soft-fail:
#   ZFS_BUILD_OPTIONAL=1 catches failures at every stage that can
#   fail when upstream OpenZFS doesn't support the current kernel
#   yet (e.g. ./configure rejecting Linux-Maximum, rpmbuild hitting
#   API breakage). On soft-fail the postinst exits 0 with an empty
#   stub so CI keeps shipping the rest of the release; deployed
#   hosts keep their prior working zfs sysext via systemd-sysext
#   version precedence.

# Bump this when OpenZFS publishes a new stable. The release META at
# https://github.com/openzfs/zfs/blob/master/META declares the
# Linux-Maximum it supports. Don't bump past that for our kernel.
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

# 1. Install build deps. The set matches OpenZFS's documented
#    Fedora/RHEL build dependencies (per
#    openzfs.github.io/openzfs-docs/Developer Resources/Building ZFS.html)
#    so ./configure picks up every optional feature instead of
#    silently disabling things. Cross-kernel build of the kmod
#    happens via `rpmbuild --rebuild --define "kernels $KVER"` from
#    the kernel-agnostic SRPM later — kernel-devel-${KVER} is what
#    that rebuild step links against.
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

# Shared helpers — kmod_exec runs chroot with real /dev /proc bound,
# kmod_unmount drops them before sysext sealing, kmod_unmount_all_under
# cleans up any /proc /dev re-mounts dnf5's rpm scriptlet pass leaves
# behind. See mkosi.shared/kmod-build.sh for the long-form reason.
. "${SRCDIR}/mkosi.shared/kmod-build.sh"

# 3. Extract + configure + make srpm-utils srpm-kmod inside the
#    buildroot. Run autogen.sh as a safety net — release tarballs
#    ship the autotools artifacts already, so autogen is a no-op,
#    but a git checkout or a partially-stripped tarball would
#    otherwise fail at ./configure. All in one sh -c so the chroot
#    crosses once and configure's state persists into make srpm-*.
#
# Why srpm-utils + srpm-kmod (vs `make rpm`):
#   `make rpm` builds binary RPMs against the running kernel only
#   — fine if uname -r == $KVER, fatal otherwise. Splitting into
#   SRPMs lets the subsequent `rpmbuild --rebuild --define
#   "kernels $KVER"` cross-build the kmod against an arbitrary
#   kernel (the buildroot's, not the host's).
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

# If we bailed out at any stage, ship an empty stub. The sealed sysext
# won't have /usr/lib/modules content, won't merge on a real host
# (SYSEXT_KERNEL_RELEASE pins it to this build's $KVER), and operators
# keep their last-good zfs sysext via systemd-sysext version precedence.
if [ "$ZFS_BUILD_BAILOUT" -eq 1 ]; then
    rm -rf "$BUILDROOT$ZFS_SRC_REL"
    kmod_unmount
    kmod_unmount_all_under "$BUILDROOT"
    kmod_ship_empty_stub zfs "zfs=$ZFS_VERSION incompatible with kernel $KVER"
    return 0
fi

# 5. Install built RPMs into the installroot. The kmod and userspace
#    have to land in a SINGLE dnf transaction — userspace zfs requires
#    `zfs-kmod = ${ZFS_VERSION}` which only the binary kmod-zfs RPM
#    provides, and dnf can't resolve that across two separate
#    --installroot calls (the first one's rpmdb isn't visible until
#    the transaction commits). Hand dnf the whole non-debug, non-devel,
#    non-test set at once and let it order the install graph.
#
# kmod selection: target the kernel-suffixed binary kmod
# (`kmod-zfs-${KVER}-${ZFS_VERSION}-*.rpm`) and exclude the meta /
# devel / debuginfo siblings. find with a literal name pattern
# treats dots as literals, so $KVER's dots match exactly.
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

# 7. Sign every ZFS / SPL kernel module with boot.key. See
#    kmod_sign_modules in kmod-build.sh for the long-form rationale.
kmod_sign_modules zfs -path '*/extra/*' \
    \( -name 'zfs*.ko*' -o -name 'spl.ko*' -o -name 'zcommon.ko*' \
    -o -name 'znvpair.ko*' -o -name 'zlua.ko*' -o -name 'zunicode.ko*' \
    -o -name 'zzstd.ko*' -o -name 'icp.ko*' \)

# 8. Strip build artifacts + dev packages before sealing the sysext.
#    Same dance as nvidia: drop bind mounts BEFORE dnf5 remove, then
#    a second sweep after to catch dnf5 scriptlet re-mounts.
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

# 8b. Re-run depmod, mark indices unique so mkosi v26 de-dup keeps
#     them, assert zfs.ko is indexed. See kmod-build.sh for full
#     background on each of the three steps.
kmod_depmod_after_strip
kmod_mark_indices_unique zfs

if ! kmod_indexed "extra/zfs/zfs.ko"; then
    echo "ERROR: zfs.ko not indexed in modules.dep after depmod." >&2
    echo "       /usr/lib/modules/$KVER/ contents:" >&2
    ls -la "$BUILDROOT/usr/lib/modules/$KVER/" >&2 || true
    exit 1
fi

# 9. Write extension-release: shared envelope from sysext-build.sh
#    plus kernel pin + reload manager marker for this kmod sysext.
. "${SRCDIR}/mkosi.shared/sysext-build.sh"
sysext_write_extension_release zfs \
    "SYSEXT_KERNEL_RELEASE=${KVER}"

# 10. Finalize sysext.
sysext_finalize

echo "zfs sysext build complete: zfs=$ZFS_VERSION kver=$KVER"
