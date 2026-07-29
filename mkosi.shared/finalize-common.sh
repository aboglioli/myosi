# Shared finalize logic for FINAL ROOT IMAGES ONLY — main myosi image
# + every sub-image whose output is a full-system bootable/runnable
# rootfs. Sourced from:
#   myosi/mkosi.finalize                         (main image)
#   myosi/mkosi.images/mybox/mkosi.finalize      (mybox nspawn DDI)
#
# DO NOT SOURCE FROM SYSEXT finalizers. The baseline-sysext bake
# below installs into /usr/share/myosi/extensions/ — that path lives
# inside the sysext overlay surface at runtime. A sysext carrying its
# own baseline_<VER>.raw would shadow main's at the host /usr
# overlay merge, tying the trust baseline to whichever sysext was
# upgraded last. Same problem for the /etc → /usr/share/factory/etc snapshot —
# sysexts have no /etc to snapshot, and any /usr/share/factory/etc they shipped
# would overlay main's at runtime.
# Sysexts use mkosi.shared/sysext-build.sh (sysext_finalize +
# strip_to_sysext_layout) which strips /etc, /var, /efi, /boot from
# the buildroot — incompatible with what this helper does.
#
# Two jobs:
#   1. Snapshot /etc → /usr/share/factory/etc (factory baseline lowerdir for the
#      runtime /etc overlay).
#   2. Wipe /etc contents — dead weight, shadowed at runtime by the
#      overlay. NOT done via RemoveFiles=/etc/* in mkosi.conf —
#      RemoveFiles= runs at step 26 of the mkosi pipeline, BEFORE
#      mkosi.finalize at step 28. Doing the wipe here ensures the
#      snapshot above ran first.
#   3. Bake any baseline sysext .raw into /usr/share/myosi/extensions/ so
#      sysext-baked-sync activates the trust baseline at first boot.
#
# Requires from caller's env: $BUILDROOT (set by mkosi), $SRCDIR (set
# by mkosi — points at the TOP-LEVEL myosi/ dir), $IMAGE_VERSION.

# 1. + 2. /etc → /usr/share/factory/etc snapshot + full wipe.
#
# The initrd does not depend on sealed-root /etc/fstab or /etc/crypttab.
# sysroot-prep.service selects the Type=var partition from the boot
# disk, unlocks it, unlocks present data-N pool members, scans btrfs,
# and mounts /sysroot/var before sysroot-etc.mount forms the overlay.
# This keeps the sealed erofs /etc empty while preserving the factory
# lowerdir under /usr/share/factory/etc.
if [ -d "$BUILDROOT/etc" ]; then
    rm -rf "$BUILDROOT/usr/share/factory/etc"
    mkdir -p "$BUILDROOT/usr/share/factory/etc"
    cp -a "$BUILDROOT/etc/." "$BUILDROOT/usr/share/factory/etc/"

    find "$BUILDROOT/etc" -mindepth 1 -delete 2>/dev/null || true
    echo "finalize-common: snapshotted /etc → /usr/share/factory/etc ($(find "$BUILDROOT/usr/share/factory/etc" -maxdepth 1 | wc -l) entries) + wiped /etc/*"
else
    echo "finalize-common: WARNING $BUILDROOT/etc missing — skipped /etc snapshot" >&2
fi

# 3. Sysext baselines (none currently).
#
# Previously baked fleet-keys_<VER>_<ARCH>.raw into
# /usr/share/myosi/extensions/ here. fleet-keys was moved to the base
# image's plain mkosi.extra (one tiny authorized_keys file — overkill
# to ship as a verity sysext) — see
# mkosi.extra/usr/share/myosi/ssh/authorized_keys.d/user.
#
# Sysext infrastructure stays in place for future baselines (firmware,
# fleet-keys-style rotations, profile-specific overlays):
#   /usr/share/myosi/extensions/                ← baked .raw files
#   /usr/libexec/myosi/sysext-baked-sync         ← symlinks them into
#                                                 /var/lib/extensions/
#   systemd-sysext.service.d/15-myosi-baked-sync.conf
#     ConditionDirectoryNotEmpty=|/usr/share/myosi/extensions
#     ExecStartPre=/usr/libexec/myosi/sysext-baked-sync
#
# When no baselines exist, /usr/share/myosi/extensions/ is empty (or
# absent). The OR-gate ConditionDirectoryNotEmpty fails together with
# the upstream four → systemd-sysext.service skips → no work.
