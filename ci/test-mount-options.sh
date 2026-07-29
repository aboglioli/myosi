#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

TMPFILES="mkosi.extra/usr/lib/tmpfiles.d/myosi.conf"
DATA_REPART="mkosi.extra/usr/lib/repart.d/90-data.conf"
HOME_MOUNT="mkosi.extra/usr/lib/systemd/system/home.mount"
SRV_MOUNT="mkosi.extra/usr/lib/systemd/system/srv.mount"
SYSROOT_PREP_SERVICE="mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/sysroot-prep.service"
SYSROOT_PREP_SCRIPT="mkosi.images/initrd/mkosi.extra/usr/libexec/myosi/sysroot-prep"
SYSROOT_ETC="mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/sysroot-etc.mount"
INITRD_CONF="mkosi.images/initrd/mkosi.conf"
RUNTIME_LUKS_POOL_RULE="mkosi.extra/usr/lib/udev/rules.d/65-myosi-luks-pool.rules"
RUNTIME_LUKS_POOL_SERVICE="mkosi.extra/usr/lib/systemd/system/myosi-luks-pool@.service"

# Static /etc/fstab and /etc/crypttab were retired from the sealed root.
# /var must still mount in the initrd, but a myosi initrd service now
# selects the Type=var partition from the boot/root disk, unlocks it as
# /dev/mapper/data, unlocks present data-N LUKS pool members, scans btrfs,
# and mounts /sysroot/var before the /etc overlay is formed.
! [ -e mkosi.extra/etc/fstab ] \
    || fail "static /etc/fstab must not ship; initrd /var mount is handled by sysroot-prep.service"
! [ -e mkosi.extra/etc/crypttab ] \
    || fail "static /etc/crypttab must not ship; initrd /var unlock is handled by sysroot-prep.service"

[ -f "$SYSROOT_PREP_SERVICE" ] \
    || fail "sysroot-prep.service must ship in the initrd"
[ -x "$SYSROOT_PREP_SCRIPT" ] \
    || fail "sysroot-prep helper must ship executable in the initrd"

grep -q '^Before=sysroot-etc\.mount initrd-fs\.target initrd-switch-root\.target$' "$SYSROOT_PREP_SERVICE" \
    || fail "sysroot-prep.service must complete before sysroot-etc.mount and switch_root"
grep -q '^ExecStart=/usr/libexec/myosi/sysroot-prep$' "$SYSROOT_PREP_SERVICE" \
    || fail "sysroot-prep.service must run sysroot-prep"
grep -q '^After=.*sysroot\.mount.*systemd-repart\.service' "$SYSROOT_PREP_SERVICE" \
    || fail "sysroot-prep.service must run after sysroot.mount and initrd repart"

! grep -q '^Requires=.*sysroot-prep\.service' "$SYSROOT_ETC" \
    || fail "sysroot-etc.mount must not require sysroot-prep.service (cascade stop on isolate unmounts the overlay)"
grep -q '^After=sysroot\.mount sysroot-prep\.service$' "$SYSROOT_ETC" \
    || fail "sysroot-etc.mount must order after sysroot-prep.service"
INITRD_FS_DROPIN="mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/initrd-fs.target.d/50-myosi.conf"
grep -q '^Requires=sysroot-prep\.service sysroot-etc\.mount$' "$INITRD_FS_DROPIN" \
    || fail "initrd-fs.target must require both sysroot-prep.service and sysroot-etc.mount"
! grep -q 'sysroot-var\.mount' "$SYSROOT_ETC" \
    || fail "sysroot-etc.mount must not depend on generator/fstab-created sysroot-var.mount"

grep -q '4d21b016-b534-45c2-a9fb-5c16e091fd2d' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must discover the primary /var partition by DPS Type=var"
grep -q 'unlock_one data "\$1"' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must unlock the primary partition as /dev/mapper/data"
grep -q 'cryptsetup luksOpen --test-passphrase --key-file "\$KEY_FILE"' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must probe the bootstrap key-file before using it"
grep -q 'systemd-cryptsetup attach "\$name" "\$dev" "\$KEY_FILE" discard' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must unlock with key-file when the key slot exists"
grep -q 'systemd-cryptsetup attach "\$name" "\$dev" - tpm2-device=auto,discard' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must fall through to TPM2/passphrase unlock when key-file is not usable"
grep -q 'data-\[0-9\]' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must unlock present data-N LUKS pool members before mounting /var"
grep -q 'btrfs device scan' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must scan btrfs devices before mounting the pool"
grep -q 'mount -t btrfs' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must mount /sysroot/var itself"
grep -q 'compress=zstd:3' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must mount /var with zstd compression level 3"
grep -q 'noatime' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must mount /var with noatime"
grep -q 'subvol=/var' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must mount the /var btrfs subvolume, not the top-level"
grep -q '/dev/mapper/data' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must use /dev/mapper/data as the primary data mapper"
! grep -q '/dev/mapper/var' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must not use /dev/mapper/var for the multi-subvolume data pool"
! grep -q 'btrfs filesystem resize' "$SYSROOT_PREP_SCRIPT" \
    || fail "sysroot-prep must not resize btrfs; that is repart/growfs responsibility"
! grep -q '65-myosi-luks-pool\.rules\|myosi-luks-pool@\.service' "$INITRD_CONF" \
    || fail "initrd must not copy the runtime udev/template LUKS pool path; sysroot-prep owns early data-N unlock"
! [ -e "$RUNTIME_LUKS_POOL_RULE" ] \
    || fail "data-N LUKS unlock must stay in sysroot-prep; runtime udev rule must not ship"
! [ -e "$RUNTIME_LUKS_POOL_SERVICE" ] \
    || fail "data-N LUKS unlock must stay in sysroot-prep; runtime myosi-luks-pool@ service must not ship"

grep -q '^Subvolumes=/var$' "$DATA_REPART" \
    || fail "data-luks repart config must create a /var btrfs subvolume"
grep -q '^Subvolumes=/home$' "$DATA_REPART" \
    || fail "data-luks repart config must create a /home btrfs subvolume"
grep -q '^Subvolumes=/srv$' "$DATA_REPART" \
    || fail "data-luks repart config must create a /srv btrfs subvolume"
grep -q '^DefaultSubvolume=/var$' "$DATA_REPART" \
    || fail "data-luks repart config must make /var the default btrfs subvolume"
for path in /var /home /srv /var/etc /var/.etc-work /var/etc/ssh /var/roothome; do
    grep -q "^MakeDirectories=${path}$" "$DATA_REPART" || \
        fail "data-luks repart config must create ${path} inside the btrfs filesystem"
done

[ -f "$HOME_MOUNT" ] \
    || fail "home.mount must ship for the /home btrfs subvolume"
grep -q '^Options=defaults,noatime,compress=zstd:3,subvol=/home$' "$HOME_MOUNT" \
    || fail "home.mount must use noatime, zstd:3, and subvol=/home"
grep -q '^What=/dev/mapper/data$' "$HOME_MOUNT" \
    || fail "home.mount must mount from /dev/mapper/data"
[ -f "$SRV_MOUNT" ] \
    || fail "srv.mount must ship for the /srv btrfs subvolume"
grep -q '^Options=defaults,noatime,compress=zstd:3,subvol=/srv$' "$SRV_MOUNT" \
    || fail "srv.mount must use noatime, zstd:3, and subvol=/srv"
grep -q '^What=/dev/mapper/data$' "$SRV_MOUNT" \
    || fail "srv.mount must mount from /dev/mapper/data"

# NoCOW (+C) coverage lives in tmpfiles `h` lines.
# Same set of paths; only the declaration mechanism changed.
for path in /var/tmp /var/cache /var/log \
    /var/lib/containers /var/lib/libvirt /var/lib/incus; do
    grep -Eq "^h ${path}[[:space:]].*\+C" "$TMPFILES" || \
        fail "tmpfiles must declare NoCOW (+C) on ${path}"
done

echo "ok - mount options"
