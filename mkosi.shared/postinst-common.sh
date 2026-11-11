# shellcheck shell=bash
# Shared postinst for FINAL ROOT IMAGES ONLY (the main image today).
# DO NOT source from sysext postinsts: sysexts overlay main's /usr at
# runtime, so version metadata / extensions written here would shadow
# main's copy (sysexts use sysext-build.sh instead). Covers preset-all,
# authselect regeneration, SELinux factory-/etc subs, /root|/mnt
# symlinks, /srv mountpoint, version metadata. Needs $BUILDROOT + $SRCDIR
# (top-level dir, set by mkosi).

# Apply preset policy — without this the preset files ship but no
# .wants/ symlinks exist until an operator runs preset-all at runtime.
chroot "$BUILDROOT" systemctl preset-all 2>/dev/null || \
    echo "postinst-common: preset-all returned non-zero (some units may be missing in this profile)"

# Alias /usr/share/factory/etc to /etc so mkosi's relabel pass labels it
# identically. Without this it gets usr_t and the runtime tmpfiles C!
# copy hands systemd wrongly-labeled files at boot → "Failed to
# initialize SELinux labeling handle" pid1 freeze.
SUBS="$BUILDROOT/etc/selinux/targeted/contexts/files/file_contexts.subs"
if [ -f "$SUBS" ]; then
    if ! grep -qE '^/usr/share/factory/etc[[:space:]]+/etc$' "$SUBS"; then
        echo "/usr/share/factory/etc /etc" >> "$SUBS"
    fi
else
    echo "postinst-common: WARNING $SUBS missing — /usr/share/factory/etc will be unlabeled"
fi

# Shadow files must not be world-readable. git cannot store mode 0000, so
# the tracked mkosi.extra/etc/shadow arrives as 0644 and would ship every
# password hash to any local reader. Fixed here, before mkosi.finalize
# snapshots /etc into the factory tree that the /etc overlay serves.
# `if`, not `[ -e ] && chmod`: the AND-list returns 1 when the file is
# absent, and as the loop's last statement that aborts the build under
# `set -e` — shadow- does not exist in a fresh buildroot.
for f in shadow gshadow shadow- gshadow-; do
    if [ -e "$BUILDROOT/etc/$f" ]; then
        chmod 0000 "$BUILDROOT/etc/$f"
    fi
done

# The authselect RPM ships the default profile, so the factory system-auth
# lacks pam_systemd_home unless it is regenerated from authselect.conf.
AS_CONF="$BUILDROOT/etc/authselect/authselect.conf"
if [ -f "$AS_CONF" ]; then
    [ -x "$BUILDROOT/usr/bin/authselect" ] || {
        echo "postinst-common: ERROR $AS_CONF exists but authselect is not installed" >&2
        exit 1
    }
    mapfile -t AS_ARGS < <(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                               -e '/^$/d' "$AS_CONF")
    if [ "${#AS_ARGS[@]}" -gt 0 ]; then
        chroot "$BUILDROOT" authselect select "${AS_ARGS[@]}" --force --nobackup
        chroot "$BUILDROOT" authselect check
    fi
    if grep -q '^with-systemd-homed' "$AS_CONF"; then
        for stack in system-auth password-auth; do
            grep -q pam_systemd_home "$BUILDROOT/etc/authselect/$stack" || {
                echo "postinst-common: ERROR /etc/authselect/$stack has no pam_systemd_home (README 3a.1)" >&2
                exit 1
            }
        done
    fi
fi

# Rootfs is read-only erofs at runtime: redirect /root → var/roothome
# and /mnt → var/mnt (tmpfiles provisions the targets each boot).
# /srv stays a real mountpoint (srv.mount, btrfs subvol on data-luks).
rm -rf "${BUILDROOT:?}/root" "${BUILDROOT:?}/mnt" "${BUILDROOT:?}/srv"
ln -s var/roothome "$BUILDROOT/root"
ln -s var/mnt      "$BUILDROOT/mnt"
mkdir -p "$BUILDROOT/srv"
# /home is a real mountpoint for home.mount; re-create defensively so a
# future base trim can't silently break the mount target.
mkdir -p "$BUILDROOT/home"

# Mountpoint for the /etc subvolume that backs the /etc overlay. The
# runtime root is read-only erofs, so nothing can create this directory at
# boot — it has to exist in the sealed image, the same way /home and /srv
# do. Dot-prefixed to keep `ls /` clean.
mkdir -p "$BUILDROOT/.etc"

# Version metadata. KVER is empty for sub-images that strip
# /usr/lib/modules → KERNEL_VERSION=unknown.
KVER=$(ls "$BUILDROOT/usr/lib/modules/" 2>/dev/null | head -1)
mkdir -p "$BUILDROOT/usr/share/myosi"
cat > "$BUILDROOT/usr/share/myosi/version" <<EOF
IMAGE_NAME=${IMAGE_ID:-myosi}
IMAGE_VERSION=${IMAGE_VERSION:-dev}
BUILD_DATE=${BUILD_DATE:-$(date -Iseconds)}
GIT_COMMIT=${GIT_COMMIT:-unknown}
FEDORA_RELEASE=44
KERNEL_VERSION=${KVER:-unknown}
EOF
