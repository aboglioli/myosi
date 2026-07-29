# Shared finalize for FINAL ROOT IMAGES ONLY (main image + mybox DDI).
# DO NOT source from sysext finalizers: anything staged under /usr here
# would shadow main's copy at the runtime overlay merge (sysexts use
# sysext-build.sh instead). Jobs: snapshot /etc → /usr/share/factory/etc,
# wipe /etc (here, not RemoveFiles= — that runs BEFORE finalize, i.e.
# before the snapshot), bake baseline sysexts. Needs $BUILDROOT, $SRCDIR.

# 1. + 2. /etc → /usr/share/factory/etc snapshot + full wipe. The initrd
# does not need sealed /etc/fstab or /etc/crypttab — sysroot-prep.service
# unlocks/mounts /sysroot/var before the /etc overlay forms.
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
# ones: baked .raws in /usr/share/myosi/extensions/ get symlinked into
# /var/lib/extensions/ by sysext-baked-sync (systemd-sysext.service
# drop-in, gated on ConditionDirectoryNotEmpty). Empty dir → no work.
