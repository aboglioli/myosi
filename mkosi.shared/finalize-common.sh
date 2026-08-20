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

    # Relative symlinks that escape /etc — issue -> ../usr/lib/issue,
    # os-release, localtime, all of fonts/conf.d — resolve correctly once
    # the tree is mounted at /etc, but dangle when anything reads the
    # factory tree at its own path. systemd-tmpfiles does exactly that for
    # `C! /etc/issue` in systemd's etc.conf and logs a stat failure every
    # boot. Rewrite them to absolute targets: identical destination through
    # the overlay, and resolvable in the factory tree as well.
    #
    # Only links whose /etc-relative target actually exists get touched, so
    # runtime-only targets (resolv.conf -> ../run/..., mtab) and genuinely
    # broken ones (grub2.cfg, man pages dropped by WithDocs=no) are left
    # exactly as the packages shipped them.
    absolutised=0
    while IFS= read -r -d '' link; do
        target=$(readlink "$link")
        case "$target" in /*) continue ;; esac
        rel=${link#"$BUILDROOT/usr/share/factory/etc/"}
        abs=$(realpath -m -s "/etc/$(dirname "$rel")/$target")
        if [ -e "$BUILDROOT$abs" ]; then
            ln -sfn "$abs" "$link"
            absolutised=$((absolutised + 1))
        fi
    done < <(find "$BUILDROOT/usr/share/factory/etc" -xtype l -print0)
    echo "finalize-common: absolutised $absolutised escaping symlinks in the factory tree"

    find "$BUILDROOT/etc" -mindepth 1 -delete 2>/dev/null || true
    echo "finalize-common: snapshotted /etc → /usr/share/factory/etc ($(find "$BUILDROOT/usr/share/factory/etc" -maxdepth 1 | wc -l) entries) + wiped /etc/*"
else
    echo "finalize-common: WARNING $BUILDROOT/etc missing — skipped /etc snapshot" >&2
fi

# 3. Sysext baselines (none currently). Infrastructure stays for future
# ones: baked .raws in /usr/share/myosi/extensions/ get selected into
# /var/lib/extensions/ by sysext-select (systemd-sysext.service
# drop-in, gated on ConditionDirectoryNotEmpty). Empty dir → no work.
