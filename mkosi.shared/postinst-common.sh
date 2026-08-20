# Shared postinst for FINAL ROOT IMAGES ONLY (the main image today).
# DO NOT source from sysext postinsts: sysexts overlay main's /usr at
# runtime, so version metadata / extensions written here would shadow
# main's copy (sysexts use sysext-build.sh instead). Covers preset-all,
# SELinux factory-/etc subs, /root|/mnt symlinks, /srv mountpoint,
# version metadata. Needs $BUILDROOT + $SRCDIR (top-level dir, set by mkosi).

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

# Rootfs is read-only erofs at runtime: redirect /root → var/roothome
# and /mnt → var/mnt (tmpfiles provisions the targets each boot).
# /srv stays a real mountpoint (srv.mount, btrfs subvol on data-luks).
rm -rf "$BUILDROOT/root" "$BUILDROOT/mnt" "$BUILDROOT/srv"
ln -s var/roothome "$BUILDROOT/root"
ln -s var/mnt      "$BUILDROOT/mnt"
mkdir -p "$BUILDROOT/srv"
# /home is a real mountpoint for home.mount; re-create defensively so a
# future base trim can't silently break the mount target.
mkdir -p "$BUILDROOT/home"

# Mountpoint for the /state subvolume that backs the /etc overlay. The
# runtime root is read-only erofs, so etc-assemble cannot create this in
# the initrd — it has to exist in the sealed image. Dot-prefixed to keep
# `ls /` clean; the same shape as mybox's /.mybox state bind.
mkdir -p "$BUILDROOT/.myosi"

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
