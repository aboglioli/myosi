# Shared finalize for FINAL ROOT IMAGES ONLY (the main image today).
# DO NOT source from sysext finalizers: anything staged under /usr here
# would shadow main's copy at the runtime overlay merge (sysexts use
# sysext-build.sh instead). Jobs: snapshot /etc → /usr/share/factory/etc,
# wipe /etc (here, not RemoveFiles= — that runs BEFORE finalize, i.e.
# before the snapshot), bake baseline sysexts. Needs $BUILDROOT, $SRCDIR.

# 1. + 2. /etc → /usr/share/factory/etc snapshot + full wipe. The sealed
# root needs no /etc/fstab or /etc/crypttab — myosi-data-attach.service
# (initrd) unlocks data-luks and sysroot-etc.mount mounts the /etc subvol
# before pivot.
if [ -d "$BUILDROOT/etc" ]; then
    rm -rf "$BUILDROOT/usr/share/factory/etc"
    mkdir -p "$BUILDROOT/usr/share/factory/etc"
    cp -a "$BUILDROOT/etc/." "$BUILDROOT/usr/share/factory/etc/"

    find "$BUILDROOT/etc" -mindepth 1 -delete 2>/dev/null || true
    echo "finalize-common: snapshotted /etc → /usr/share/factory/etc ($(find "$BUILDROOT/usr/share/factory/etc" -maxdepth 1 | wc -l) entries) + wiped /etc/*"
else
    echo "finalize-common: WARNING $BUILDROOT/etc missing — skipped /etc snapshot" >&2
fi

# 3. Sysext baselines (none currently). Infrastructure stays for future
# ones: baked .raws in /usr/share/myosi/extensions/ get selected into
# /var/lib/extensions/ by sysext-select (systemd-sysext.service
# drop-in, gated on ConditionDirectoryNotEmpty). Empty dir → no work.
