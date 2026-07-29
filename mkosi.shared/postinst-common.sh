# Shared postinst logic for FINAL ROOT IMAGES ONLY — main myosi image
# + every sub-image whose output is a full-system bootable/runnable
# rootfs. Sourced from:
#   myosi/mkosi.postinst                         (main image)
#   myosi/mkosi.images/mybox/mkosi.postinst      (mybox nspawn DDI)
#
# DO NOT SOURCE FROM SYSEXT postinsts (desktop, containers, virt,
# nvidia, nvidia-580xx, zfs). Sysexts have a completely
# different lifecycle:
#   - Format=sysext, Overlay=yes → /usr-only artifact
#   - strip_to_sysext_layout drops /etc, /var, /root, /srv, /mnt
#   - Sysext content overlays main's /usr at runtime, so anything
#     this helper writes to /usr/share/myosi/version or
#     /usr/share/myosi/extensions/ would SHADOW main's copy at
#     runtime — baseline sysexts end up tied to whichever sysext
#     was upgraded last, version metadata reports the wrong IMAGE_NAME.
# Sysexts use mkosi.shared/sysext-build.sh instead (sysext_finalize +
# strip_to_sysext_layout + stage_sysext_policy + stage_sandbox_repos).
#
# Single source of truth for: systemctl preset-all, SELinux /usr/share/factory/etc
# alias subs, /root|/mnt → var/* symlinks, /srv mountpoint, version
# metadata stash.
#
# Requires from caller's env: $BUILDROOT (set by mkosi), $SRCDIR
# (set by mkosi — points at the TOP-LEVEL myosi/ dir even for
# sub-image builds; verified via nvidia/mkosi.postinst pattern).
#
# Image-specific additions (MOK certs + LUKS key for the main image,
# boot-stack masks for the mybox sub-image) live in each caller's
# own mkosi.postinst alongside the `source` line.

# Apply systemd preset policy (40-myosi-fedora.preset +
# 50-myosi.preset + 99-default-disable.preset). Without this, the
# preset files ship but no .wants/ symlinks are written until the
# operator runs `systemctl preset-all` at runtime.
chroot "$BUILDROOT" systemctl preset-all 2>/dev/null || \
    echo "postinst-common: preset-all returned non-zero (some units may be missing in this profile)"

# Teach SELinux that /usr/share/factory/etc is aliased to /etc, so the next setfiles
# run (mkosi's own relabel pass at step 27) labels its contents
# identically. Without this, /usr/share/factory/etc ends up labeled under /usr rules
# (usr_t) and the runtime systemd-tmpfiles C! copy from /usr/share/factory/etc to
# /etc would hand systemd unlabeled-vs-etc files at boot →
# "Failed to initialize SELinux labeling handle" pid1 freeze.
#
# The /var/etc /etc subs alias was retired alongside the /etc overlay
# in the etc-subvol refactor: /etc is now a real persistent btrfs
# subvolume on data-luks (no upperdir on /var/etc), so the alias has
# no targets to label.
SUBS="$BUILDROOT/etc/selinux/targeted/contexts/files/file_contexts.subs"
if [ -f "$SUBS" ]; then
    if ! grep -qE '^/usr/share/factory/etc[[:space:]]+/etc$' "$SUBS"; then
        echo "/usr/share/factory/etc /etc" >> "$SUBS"
    fi
else
    echo "postinst-common: WARNING $SUBS missing — /usr/share/factory/etc will be unlabeled"
fi

# /root and /mnt → var/* symlinks. The rootfs is read-only erofs
# at runtime, so writes under these paths would fail with EROFS
# unless redirected onto the writable /var:
#   /root → var/roothome   (homedir for root, accessed by incus init,
#                           gh CLI cache, root-cron rsync targets, …)
#   /mnt  → var/mnt        (operator-mounted block devices,
#                           USB sticks, NFS shares, foreign root
#                           filesystems for migration)
# /srv is a real mountpoint. srv.mount mounts the /srv btrfs subvolume
# from data-luks before local-fs.target.
# Target dirs under /var are provisioned every boot by tmpfiles.
rm -rf "$BUILDROOT/root" "$BUILDROOT/mnt" "$BUILDROOT/srv"
ln -s var/roothome "$BUILDROOT/root"
ln -s var/mnt      "$BUILDROOT/mnt"
mkdir -p "$BUILDROOT/srv"
# /home stays as a real mountpoint for home.mount. Fedora's base
# image ships /home, but defensively re-create it here so a future
# base trim does not silently turn home.mount into "missing target".
mkdir -p "$BUILDROOT/home"

# Stash version metadata. IMAGE_ID comes from mkosi (set per sub-image
# build to the value of [Output] ImageId=). KVER comes from
# /usr/lib/modules/<KVER>/ if a kernel is present; for sub-images that
# strip /usr/lib/modules (mybox), this lookup returns empty and the
# field reads KERNEL_VERSION=unknown.
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

# The myenv repo is deliberately NOT baked into /usr/share/myenv.
# A host-side stage in the justfile used to do it, but nothing in the
# image consumed the tree (bin/myenv resolves $MYENV, default
# $HOME/myenv), so it was pure image weight plus a second copy that
# drifted from the user's clone. Clone into $HOME instead.
#
# GIT_COMMIT above still comes from the caller (`just build` and the CI
# workflow both export it); it defaults to `unknown` if unset.
