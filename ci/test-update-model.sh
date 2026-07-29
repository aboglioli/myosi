#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Transfer files must read from local cache, not direct URLs.
assert_local_transfer() {
    local file="$1"
    grep -q '^Type=regular-file$' "$file" || fail "$file must use Type=regular-file"
    grep -q '^Path=/var/lib/sysupdate$' "$file" || fail "$file must read from /var/lib/sysupdate"
    ! grep -q '^Type=url-file$' "$file" || fail "$file must not use Type=url-file"
    ! grep -q '^Path=https://' "$file" || fail "$file must not read directly from GitHub"
}

for file in \
    mkosi.extra/usr/lib/sysupdate.d/10-root.transfer \
    mkosi.extra/usr/lib/sysupdate.d/11-verity.transfer \
    mkosi.extra/usr/lib/sysupdate.d/12-verity-sig.transfer \
    mkosi.extra/usr/lib/sysupdate.d/20-uki.transfer; do
    assert_local_transfer "$file"
done

# The root + verity transfer files MUST embed @u in the source
# MatchPattern. Without it, sysupdate leaves the old placeholder
# PARTUUID on the partition after writing new content, and
# systemd-veritysetup-generator cannot find the partition by the
# roothash-derived PARTUUID it expects from the Discoverable
# Partitions Spec. Regression caught on 2026.06.06.04 (host stuck
# at dev-mapper-root.device timeout, dropped to emergency).
grep -q '^MatchPattern=myosi_@v_%a_@u\.root\.raw\.zst$' \
    mkosi.extra/usr/lib/sysupdate.d/10-root.transfer \
    || fail "10-root.transfer must use MatchPattern=myosi_@v_%a_@u.root.raw.zst (%a pins host arch, @u captures roothash-derived PartitionUUID)"
grep -q '^MatchPattern=myosi_@v_%a_@u\.verity\.raw\.zst$' \
    mkosi.extra/usr/lib/sysupdate.d/11-verity.transfer \
    || fail "11-verity.transfer must use MatchPattern=myosi_@v_%a_@u.verity.raw.zst (%a pins host arch, @u captures roothash-derived PartitionUUID)"

# The fetch recipe must download by glob (the UUID is unknown until
# the artifacts are inspected — gh release download --pattern handles
# globs). Arch is interpolated from the host's uname before the glob.
grep -q 'myosi_\${VERSION}_\${ARCH}_\*\.root\.raw\.zst' \
    mkosi.extra/usr/share/myosi/just/00-update.just \
    || fail "fetch recipe must download myosi_VER_ARCH_*.root.raw.zst (glob, not exact filename)"
grep -q 'myosi_\${VERSION}_\${ARCH}_\*\.verity\.raw\.zst' \
    mkosi.extra/usr/share/myosi/just/00-update.just \
    || fail "fetch recipe must download myosi_VER_ARCH_*.verity.raw.zst (glob, not exact filename)"

# scripts/stage-artifacts.sh renames root + verity artifacts to embed
# the PartitionUUID derived from the verity roothash. Runs EXPLICITLY
# after `mkosi build` (in both CI and `just build`) — NOT as a
# mkosi.finalize hook, because mkosi v26 runs finalize hooks before
# the UKI is staged at OUTPUTDIR. The 2026.06.07.02 release shipped
# unstamped because mkosi.finalize logged
# "no UKI at /work/out/myosi_2026.06.07.02.efi; skipping rename"
# even though the UKI ended up in build/ after mkosi finished.
[ -x scripts/stage-artifacts.sh ] \
    || fail "scripts/stage-artifacts.sh must exist and be executable (rename root + verity to embed PartitionUUID per Discoverable Partitions Spec)"
# scripts/decode-keys.sh must resolve the keys/ directory as one level
# UP from its own location (i.e. keys/), not two levels up. The
# 2026.06.07.03 release failed at "tools image cert validation" because
# the move from ci/lib/decode-keys.sh -> scripts/decode-keys.sh
# kept the old `${BASH_SOURCE}/../..` pattern, which now points at the
# repo root instead of myosi/. Keys landed at <repo>/keys/, mkosi
# read keys/, build aborted with
#   Failed to load X.509 certificate from /keys/image.crt
! grep -q '$(dirname "${BASH_SOURCE\[0\]}")/\.\./\.\."' scripts/decode-keys.sh \
    || fail "scripts/decode-keys.sh must not traverse two levels up — that was correct when the script lived at ci/lib/ but now writes to <repo>/keys/ instead of keys/, breaking mkosi cert validation"
grep -q 'SCRIPT_DIR}/\.\./keys' scripts/decode-keys.sh \
    || fail "scripts/decode-keys.sh must compute DST as \${SCRIPT_DIR}/../keys so keys land in keys/"
grep -q 'ukify inspect' scripts/stage-artifacts.sh \
    || fail "stage-artifacts.sh must use ukify inspect to extract roothash from the UKI"
# `ukify inspect` dumps binary PE sections (.linux, .initrd) alongside
# the textual headers. GNU grep auto-detects NUL bytes and, with -o,
# emits "binary file matches" on stderr instead of the actual matching
# text. Locally on ukify 259.5 the roothash appears before the first
# NUL so the bug is invisible; on ukify 259.6 (CI runner) the NULs
# appear earlier and the extraction silently returns empty. Force
# text mode with `-a` to keep the extractor robust across versions.
grep -q 'grep -a' scripts/stage-artifacts.sh \
    || fail "stage-artifacts.sh must pass -a (--binary-files=text) to grep when parsing ukify inspect output (newer ukify emits NUL bytes before the .cmdline text section; without -a the roothash extraction silently returns empty, observed on 2026.06.07.04 GitHub Action release)"
grep -q 'ROOT_UUID' scripts/stage-artifacts.sh \
    || fail "stage-artifacts.sh must compute ROOT_UUID from the first 16 bytes of roothash"
grep -q 'VERITY_UUID' scripts/stage-artifacts.sh \
    || fail "stage-artifacts.sh must compute VERITY_UUID from the last 16 bytes of roothash"
# mkosi.finalize MUST exist and be executable. It snapshots the settled
# /etc into /usr/share/factory/etc (the verity-baked factory tree used by tmpfiles'
# C! rule to seed the empty /etc subvol on first boot) and bakes the
# fleet-keys baseline sysext into the verity-immutable
# /usr/share/myosi/extensions/ tree. mkosi v26 runs finalize at the
# right point in the build pipeline for both of those operations
# (post-package-install, post-postinst).
[ -x mkosi.finalize ] \
    || fail "mkosi.finalize must exist and be executable"
grep -q 'mkosi.shared/finalize-common.sh' mkosi.finalize \
    || fail "mkosi.finalize must source shared finalize logic"
grep -q 'cp -a "\$BUILDROOT/etc/\." "\$BUILDROOT/usr/share/factory/etc/"' mkosi.shared/finalize-common.sh \
    || fail "finalize-common.sh must snapshot settled /etc into /usr/share/factory/etc (the factory tree tmpfiles C! copies from on first boot)"
grep -q 'find "\$BUILDROOT/etc" -mindepth 1 -delete' mkosi.shared/finalize-common.sh \
    || fail "finalize-common.sh must wipe sealed-root /etc after snapshotting it"
grep -q 'usr/share/myosi/extensions' mkosi.shared/finalize-common.sh \
    || fail "finalize-common.sh must bake the fleet-keys baseline sysext into /usr/share/myosi/extensions/"
grep -q 'fleet-keys_' mkosi.shared/finalize-common.sh \
    || fail "finalize-common.sh must embed the fleet-keys baseline raw"
# Both `just build` and CI must invoke stage-artifacts.sh post-mkosi.
grep -q 'stage-artifacts.sh' justfile \
    || fail "justfile must invoke scripts/stage-artifacts.sh after mkosi build"
grep -q 'stage-artifacts.sh' .github/workflows/build.yml \
    || fail ".github/workflows/myosi.yml must invoke scripts/stage-artifacts.sh after the build step"
# CI workflow consumes already-renamed artifacts; must not have a
# separate Python rename step (that lived briefly between the
# 2026.06.06.04 regression and the mkosi.finalize move).
! grep -q 'python3 <<.PY' .github/workflows/build.yml \
    || fail ".github/workflows/myosi.yml must not run inline python to rename artifacts (scripts/stage-artifacts.sh handles it now)"

# CI workflow build job must install every host-side CLI in a single
# consolidated step (not scattered across the workflow). Only
# systemd-ukify is needed today — `ukify inspect` covers both
# mkosi.finalize's roothash extraction AND the "Extract kernel
# version" step's .uname read. systemd-dissect was previously used
# but hung on ubuntu-24.04 systemd 255+ verity-sig verification
# (2026.06.07.01 release stuck >35 min).
grep -q 'systemd-ukify' .github/workflows/build.yml \
    || fail ".github/workflows/myosi.yml must install systemd-ukify on the runner"
grep -q 'Install runner build tools' .github/workflows/build.yml \
    || fail ".github/workflows/myosi.yml must consolidate runner-tool installs into a single step named 'Install runner build tools'"

# The kernel version extraction step must not call systemd-dissect
# (it hangs on self-signed verity images under newer systemd). Must
# use `ukify inspect` reading the UKI's .uname section. Filter
# comments so the rationale block referring to the old approach
# doesn't trip the check.
! grep -vE '^\s*#' .github/workflows/build.yml \
    | grep -q 'systemd-dissect' \
    || fail ".github/workflows/myosi.yml must not call systemd-dissect (hangs on self-signed verity sigs under ubuntu-24.04 systemd 255+; use ukify inspect instead)"
grep -q 'ukify inspect' .github/workflows/build.yml \
    || fail ".github/workflows/myosi.yml must use 'ukify inspect' to extract the kernel version from the UKI's .uname section"

# stage-artifacts.sh must fail hard if ukify is missing or roothash
# extraction fails — silent fallthrough produced the 2026.06.06.04
# release that broke sysupdate boots in the field.
grep -q 'exit 1' scripts/stage-artifacts.sh \
    || fail "stage-artifacts.sh must fail hard (exit 1) when ukify is missing or no roothash found"

for file in mkosi.extra/usr/lib/sysupdate.extensions.d/*.transfer; do
    assert_local_transfer "$file"
    grep -q '^InstancesMax=2$' "$file" || fail "$file must retain two installed versions"
done

# Verify the myosi wrapper exists. There is no static justfile — the
# wrapper builds /run/justfile dynamically each invocation by
# scanning /usr/share/myosi/just/, so sysexts can drop their own
# NN-<name>.just modules without the base image enumerating them.
[ -x mkosi.extra/usr/local/bin/myosi ] || fail "myosi wrapper must exist and be executable"

# Verify update recipes are present in the just modules. `update` is the
# all-in-one fetch+apply entry point; the old `run` alias is deliberately
# absent so operators use `sudo myosi update`.
for recipe in fetch apply update status vacuum; do
    grep -q "^${recipe}" mkosi.extra/usr/share/myosi/just/00-update.just \
        || fail "update just module must define $recipe recipe"
done
! grep -q '^run ' mkosi.extra/usr/share/myosi/just/00-update.just \
    || fail "update just module must not define the old run recipe"
grep -q 'usage: myosi update \[--refresh\] \[VERSION\]' mkosi.extra/usr/share/myosi/just/00-update.just \
    || fail "update recipe must support the operator-facing form: myosi update [--refresh] [VERSION]"
! grep -q '00-update.just update' mkosi.extra/usr/share/myosi/just/10-extensions.just \
    || fail "extension-enable must not call the full-system update recipe"
grep -q 'download_release_asset' mkosi.extra/usr/share/myosi/just/10-extensions.just \
    || fail "extension-enable must download only the requested sysext asset"
grep -q '/var/lib/extensions' mkosi.extra/usr/share/myosi/just/10-extensions.just \
    || fail "extension-enable must install the requested sysext into /var/lib/extensions directly"

# Verify the myosi-specific orchestration modules exist. Day-2 ops
# (storage / data-luks / portables / credentials / factory-reset) are
# operator-managed via upstream tools directly — those recipes are
# intentionally not in the wrapper.
for mod in 00-update 10-extensions 40-install; do
    [ -f "mkosi.extra/usr/share/myosi/just/${mod}.just" ] || fail "missing just module: $mod"
done

# Verify lib.sh still exists (shared library)
[ -f mkosi.extra/usr/libexec/myosi/lib.sh ] || fail "lib.sh must still exist in libexec"

# Install script must ship at /usr/libexec/myosi/install (single source of
# truth — dev `just install` and operator `myosi install` both call it).
[ -x mkosi.extra/usr/libexec/myosi/install ] || fail "install script must ship at /usr/libexec/myosi/install and be executable"

# Kmod sysexts ship .ko files but mkosi v26 strips the modules.{dep,alias,
# symbols,...} index files at seal time (path-based dedup against base-tree).
# The host-side fix is /usr/libexec/myosi/sysext-modules-refresh, invoked as an
# ExecStartPost= of systemd-sysext.service. It stacks a tmpfs overlay on
# /usr/lib/modules/<KVER>/, runs depmod -a, then directly modprobes every
# entry in modules-load.d/*.conf from the same shell process. Standalone
# myosi-depmod.service was retired — the drop-in lives inside
# systemd-sysext.service.d/10-myosi-rerun-sysinit.conf now.
[ -x mkosi.extra/usr/libexec/myosi/sysext-modules-refresh ] \
    || fail "sysext-modules-refresh helper must ship at /usr/libexec/myosi/sysext-modules-refresh and be executable"
! [ -e mkosi.extra/usr/lib/systemd/system/myosi-depmod.service ] \
    || fail "myosi-depmod.service was retired — replay lives in systemd-sysext.service.d/10-myosi-rerun-sysinit.conf ExecStartPost=-/usr/libexec/myosi/sysext-modules-refresh"
! grep -q '^enable myosi-depmod\.service' mkosi.extra/usr/lib/systemd/system-preset/50-myosi.preset \
    || fail "50-myosi.preset must NOT enable retired myosi-depmod.service"
# sysext-modules-refresh's own internals: modules-load.d processing must be
# deduplicated by basename (matches systemd-modules-load's
# /etc > /run > /usr/lib priority), and modprobe must be called.
grep -q 'declare -A modload_cfgs' mkosi.extra/usr/libexec/myosi/sysext-modules-refresh \
    || fail "sysext-modules-refresh must build a basename-deduplicated map of modules-load.d configs (matches systemd-modules-load priority)"
grep -q 'modprobe -q "\$mod"' mkosi.extra/usr/libexec/myosi/sysext-modules-refresh \
    || fail "sysext-modules-refresh must invoke modprobe directly in the same process that just finished depmod (avoids libkmod stale-cache race)"
# Initrd modprobe-defer drop-in: prevents iwlwifi / btusb / btintel from
# loading inside the initrd, so udev coldplug picks them up post-pivot
# with the deployed root's full /usr/lib/firmware/ visible. Replaced
# the earlier post-pivot rmmod+modprobe recovery (myosi-firmware-reprobe
# .service, retired) — same fix, declarative.
DEFER=mkosi.images/initrd/mkosi.extra/etc/modprobe.d/00-defer.conf
[ -f "$DEFER" ] \
    || fail "$DEFER must ship in initrd-extras to defer wifi/BT module load to post-switch_root"
for mod in iwlwifi btusb btintel; do
    grep -qE "^install +${mod} +/bin/false" "$DEFER" \
        || fail "$DEFER must block ${mod} from loading in the initrd"
done
! [ -f mkosi.extra/usr/lib/systemd/system/myosi-firmware-reprobe.service ] \
    || fail "myosi-firmware-reprobe.service was retired (replaced by initrd modprobe-defer drop-in)"
# sysinit replay (sysusers/binfmt/sysctl/tmpfiles + sysext-modules-refresh) is
# wired into systemd-sysext.service via ExecStartPost=, NOT a separate
# myosi-sysusers-after-sysext.service. The drop-in lives in
# /usr/lib/systemd/system/systemd-sysext.service.d/10-myosi-rerun-sysinit.conf.
# This guarantees the replay fires on every boot AND on every
# `systemd-sysext refresh` (a separate oneshot unit only runs at boot).
SYSEXT_DROPIN=mkosi.extra/usr/lib/systemd/system/systemd-sysext.service.d/10-myosi-rerun-sysinit.conf
[ -f "$SYSEXT_DROPIN" ] \
    || fail "systemd-sysext post-merge replay drop-in must ship at $SYSEXT_DROPIN"
grep -q '^ExecStartPost=-/usr/libexec/myosi/sysext-modules-refresh$' "$SYSEXT_DROPIN" \
    || fail "sysext replay must run sysext-modules-refresh first (overlay-based modules.dep regeneration + same-process modprobe)"
grep -q '^ExecStartPost=-/usr/bin/systemd-sysusers$' "$SYSEXT_DROPIN" \
    || fail "sysext replay must re-run systemd-sysusers so sysext-shipped sysusers.d fragments are processed"
grep -q '^ExecStartPost=-/usr/lib/systemd/systemd-binfmt$' "$SYSEXT_DROPIN" \
    || fail "sysext replay must re-run systemd-binfmt"
grep -q '^ExecStartPost=-/usr/lib/systemd/systemd-sysctl$' "$SYSEXT_DROPIN" \
    || fail "sysext replay must re-run systemd-sysctl"
grep -q '^ExecStartPost=-/usr/bin/systemd-tmpfiles --create$' "$SYSEXT_DROPIN" \
    || fail "sysext replay must re-run tmpfiles --create"
# systemd-modules-load is deliberately NOT called as a fallback: it
# would spawn a separate process subject to the libkmod stale-cache
# race that sysext-modules-refresh's same-process modprobe loop already
# avoids. Its failure mode is spurious "Failed to find module" logs
# even though modprobe inside sysext-modules-refresh already loaded them.
! grep -q '^ExecStartPost=-/usr/lib/systemd/systemd-modules-load$' "$SYSEXT_DROPIN" \
    || fail "sysext drop-in must NOT call systemd-modules-load — sysext-modules-refresh loads modules directly; the redundant call produced spurious failure logs"
# Retired standalone myosi-sysusers-after-sysext.service unit must not
# come back (replaced by the ExecStartPost above).
! [ -e mkosi.extra/usr/lib/systemd/system/myosi-sysusers-after-sysext.service ] \
    || fail "myosi-sysusers-after-sysext.service was retired — replay is now in systemd-sysext.service.d/10-myosi-rerun-sysinit.conf"
! grep -q '^enable myosi-sysusers-after-sysext\.service' mkosi.extra/usr/lib/systemd/system-preset/50-myosi.preset \
    || fail "50-myosi.preset must not enable retired myosi-sysusers-after-sysext.service"
# Baseline sysext sync — separate drop-in that runs ExecStartPre so
# image-baked /usr/share/myosi/extensions/ raws are materialized as
# symlinks into /var/lib/extensions/ before sysext merge. systemd-sysext
# does NOT discover from /usr/share/myosi/extensions/ or /usr/lib/extensions/
# directly on F44/259; the symlink sync bridges that gap.
BAKED_SYNC_DROPIN=mkosi.extra/usr/lib/systemd/system/systemd-sysext.service.d/15-myosi-baked-sync.conf
[ -f "$BAKED_SYNC_DROPIN" ] \
    || fail "systemd-sysext baked-sync drop-in must ship at $BAKED_SYNC_DROPIN"
grep -q '^ExecStartPre=/usr/libexec/myosi/sysext-baked-sync$' "$BAKED_SYNC_DROPIN" \
    || fail "sysext drop-in must call sysext-baked-sync as ExecStartPre to materialize baked sysext symlinks before merge"
# Gate extension to /usr/share/myosi/extensions. Without it, upstream
# sysext.service skips on first boot when /var/lib/extensions/ is empty,
# ExecStartPre never runs, no symlinks materialize, fleet-keys never
# merges. Verified empirically in .16.01 VM testing — systemd-sysext
# status reported `none` until this gate was added.
grep -q '^ConditionDirectoryNotEmpty=|/usr/share/myosi/extensions$' "$BAKED_SYNC_DROPIN" \
    || fail "baked-sync drop-in must extend ConditionDirectoryNotEmpty to /usr/share/myosi/extensions so the gate fires on first boot when only the baked baseline exists"
# myosi-sysext-relabel.service MUST order Before=sshd-keygen.target.
# Without this ordering, sshd-keygen@{rsa,ecdsa,ed25519}.service run
# concurrently with the relabel on FIRST BOOT, get SELinux-denied
# writing host keys to unlabeled /var/etc/ssh/, and SSH is unavailable
# until the second boot. Verified empirically on 2026.06.16.01 VM.
RELABEL=mkosi.extra/usr/lib/systemd/system/myosi-sysext-relabel.service
grep -qE '^Before=.*\bsshd-keygen\.target\b' "$RELABEL" \
    || fail "myosi-sysext-relabel.service must order Before=sshd-keygen.target so /var/etc/ssh has correct SELinux labels before sshd-keygen@*.service writes host keys (first-boot race fix)"
# myosi-firstboot-relabel.service was RETIRED in the etc-subvol refactor.
# /etc is now a real persistent btrfs subvolume on data-luks (not an
# overlay with /var/etc upperdir), seeded on first boot by systemd-
# tmpfiles' C! directive from /usr/share/factory/etc. SELinux labels inherit from the
# baked /usr/share/factory/etc tree at copy time, so no first-boot restorecon pass is
# needed.
! [ -e mkosi.extra/usr/lib/systemd/system/myosi-firstboot-relabel.service ] \
    || fail "myosi-firstboot-relabel.service was retired in the etc-subvol refactor — /etc is a real btrfs subvol seeded from /usr/share/factory/etc via tmpfiles C!, labels inherit at copy time, no relabel pass needed"
! grep -q '^enable myosi-firstboot-relabel\.service$' mkosi.extra/usr/lib/systemd/system-preset/50-myosi.preset \
    || fail "50-myosi.preset must NOT enable retired myosi-firstboot-relabel.service"
# /etc seeding lives in myosi-etc-seed.service in the initrd (asserted
# below). The previous tmpfiles `C! /etc - - - - /usr/share/factory/etc` rule was
# retired — C! is directory-level (only fires on empty target), so it
# can't propagate new factory files on image upgrades, and once /etc
# is populated by the initrd it never fires again. The dedicated
# initrd unit is the single source of truth.
# Declarative authselect selection. Ship /etc/authselect/authselect.conf
# with the features we want (local + with-systemd-homed + with-pam-
# gnome-keyring); Fedora's authselect-apply-changes.service runs at
# every boot, reads the conf, and re-renders the pam.d files. No
# custom service, no runtime authselect call, no hand-baked pam.d
# files.
AUTHSELECT_CONF=mkosi.extra/etc/authselect/authselect.conf
[ -f "$AUTHSELECT_CONF" ] \
    || fail "$AUTHSELECT_CONF must ship — authselect-apply-changes.service reads it and renders the PAM stack at every boot"
grep -q '^local$' "$AUTHSELECT_CONF" \
    || fail "$AUTHSELECT_CONF must select the 'local' profile (matches Fedora's default profile choice; minimal local-only auth)"
grep -q '^with-systemd-homed$' "$AUTHSELECT_CONF" \
    || fail "$AUTHSELECT_CONF must enable with-systemd-homed (homed users authenticate via pam_systemd_home; without this homectl-managed accounts fail every login)"
grep -q '^with-pam-gnome-keyring$' "$AUTHSELECT_CONF" \
    || fail "$AUTHSELECT_CONF must enable with-pam-gnome-keyring (desktop sessions need pam_gnome_keyring to auto-unlock the keyring on PAM success)"
! [ -e mkosi.extra/usr/lib/systemd/system/myosi-firstboot-pam.service ] \
    || fail "myosi-firstboot-pam.service must NOT ship — the baked authselect.conf + Fedora's authselect-apply-changes.service replaces it"
! [ -e mkosi.extra/etc/authselect/system-auth ] \
    || fail "mkosi.extra/etc/authselect/system-auth must NOT ship — Fedora's authselect-apply-changes.service renders it at every boot from authselect.conf"
! [ -e mkosi.extra/etc/authselect/password-auth ] \
    || fail "mkosi.extra/etc/authselect/password-auth must NOT ship — Fedora's authselect-apply-changes.service renders it at every boot from authselect.conf"
! [ -d mkosi.extra/usr/share/factory/etc/pam.d ] \
    || fail "factory pam.d overrides must NOT ship — the authselect runtime render is the source of truth"
# sysroot-prep was renamed myosi-data-attach in the etc-subvol
# refactor and narrowed: LUKS unlock + multi-disk pool unlock + btrfs
# scan + /etc subvol seed-and-label. Only one declarative .mount unit
# fires in the initrd (sysroot-etc.mount); /var is mounted post-pivot
# by gpt-auto-generator from the Type=var partition + DefaultSubvolume
# (same lifecycle as home.mount and srv.mount).
DATA_ATTACH_SCRIPT=mkosi.images/initrd/mkosi.extra/usr/libexec/myosi/data-attach
DATA_ATTACH_UNIT=mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/myosi-data-attach.service
[ -x "$DATA_ATTACH_SCRIPT" ] \
    || fail "$DATA_ATTACH_SCRIPT must ship and be executable (LUKS unlock + multi-disk pool unlock + btrfs scan in the initrd)"
! [ -e mkosi.images/initrd/mkosi.extra/usr/libexec/myosi/sysroot-prep ] \
    || fail "sysroot-prep was renamed myosi-data-attach in the etc-subvol refactor — the legacy script must not coexist with the renamed one"
[ -f "$DATA_ATTACH_UNIT" ] \
    || fail "$DATA_ATTACH_UNIT must ship — wraps data-attach so sysroot-etc.mount can order After= it"
! [ -e mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/myosi-sysroot-prep.service ] \
    || fail "myosi-sysroot-prep.service was renamed myosi-data-attach.service — the legacy unit must not ship"
grep -qE '^ExecStart=/usr/libexec/myosi/data-attach$' "$DATA_ATTACH_UNIT" \
    || fail "$DATA_ATTACH_UNIT must invoke /usr/libexec/myosi/data-attach"
grep -qE '^Before=.*sysroot-etc\.mount' "$DATA_ATTACH_UNIT" \
    || fail "$DATA_ATTACH_UNIT must order Before=sysroot-etc.mount so /etc mounts AFTER LUKS is unlocked"
# Forbid a sysroot-var.mount from being re-introduced — /var is
# mounted post-pivot by gpt-auto-generator from the Type=var partition
# + DefaultSubvolume=/var (see 90-data.conf), same lifecycle as
# home.mount and srv.mount. The initrd does NOT need to mount /var
# because nothing in the initrd phase reads /var.
! [ -e mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/sysroot-var.mount ] \
    || fail "sysroot-var.mount must NOT ship — /var is mounted post-pivot by gpt-auto-generator (Type=var + DefaultSubvolume=/var). The initrd has nothing to read from /var; keeping a sysroot-var.mount duplicates the lifecycle."
! grep -qE 'mount[[:space:]]+[^|;&]*/sysroot/(var|etc)\b' "$DATA_ATTACH_SCRIPT" \
    || fail "data-attach must NOT mount /sysroot/var or /sysroot/etc — /sysroot/etc lives in sysroot-etc.mount (declarative); /sysroot/var is handled post-pivot by gpt-auto-generator"
# sshd-keygen serial drop-ins retired with the /etc overlay. The
# copy_up race that bit parallel sshd-keygen@{rsa,ecdsa,ed25519}
# instances against the /var/etc upperdir is gone now that /etc is a
# real persistent btrfs subvolume — parallel writes to /etc/ssh/ no
# longer race a copy_up. Keep the drop-ins from coming back.
for drop in ecdsa ed25519; do
    ! [ -e "mkosi.extra/usr/lib/systemd/system/sshd-keygen@${drop}.service.d/10-myosi-serial.conf" ] \
        || fail "sshd-keygen@${drop}.service.d/10-myosi-serial.conf was retired alongside the /etc overlay — parallel keygen no longer races a copy_up against /var/etc"
done

# data-attach script is intentionally narrow now: LUKS unlock +
# pool unlock + btrfs scan. /etc subvol prep moved out into
# myosi-etc-seed.service.
! grep -q 'prepare_etc_subvol\|label_etc_subvol_root' "$DATA_ATTACH_SCRIPT" \
    || fail "data-attach must NOT carry /etc subvol prep — split into myosi-etc-seed.service (ConditionDirectoryNotEmpty=!/sysroot/etc gated; cp + setfattr)"
! grep -q 'setfattr\|/usr/share/factory/etc' "$DATA_ATTACH_SCRIPT" \
    || fail "data-attach must NOT reference setfattr or /usr/share/factory/etc — those belong in myosi-etc-seed.service"
! grep -qE '(btrfs subvolume create|mv .*legacy-overlay)' "$DATA_ATTACH_SCRIPT" \
    || fail "data-attach must NOT carry migration code (subvol create / mv legacy upperdir). Upgrade hosts create /etc manually per README §upgrade runbook; fresh installs get it from repart's Subvolumes=/etc at format time"

# myosi-etc-seed.service: separate oneshot, fires only on first boot
# when /sysroot/etc is empty. cp + setfattr inline ExecStart=.
ETC_SEED_UNIT=mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/myosi-etc-seed.service
[ -f "$ETC_SEED_UNIT" ] \
    || fail "$ETC_SEED_UNIT must ship — seeds /etc subvol from /sysroot/usr/share/factory/etc on first boot + setfattr etc_t on subvol root, between sysroot-etc.mount and initrd-switch-root.target"
# Six static .wants symlinks — three units × two target dirs.
# initrd.target.wants/ activates the chain during the normal initrd
# phase. initrd-switch-root.target.wants/ preserves the chain through
# the initrd-cleanup isolate. mkosi-initrd does NOT run preset-all so
# the [Install] WantedBy= lines are documentation only — the symlinks
# are what activate the units.
INITRD_TGT_DIR=mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/initrd.target.wants
SWITCH_TGT_DIR=mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/initrd-switch-root.target.wants
for unit in myosi-data-attach.service sysroot-etc.mount myosi-etc-seed.service; do
    for dir in "$INITRD_TGT_DIR" "$SWITCH_TGT_DIR"; do
        [ -L "$dir/$unit" ] \
            || fail "$dir/$unit must ship as a static .wants/ symlink — three units (data-attach, sysroot-etc.mount, etc-seed) × two target dirs (initrd.target.wants, initrd-switch-root.target.wants) = 6 symlinks total"
        [ "$(readlink "$dir/$unit")" = "../$unit" ] \
            || fail "$dir/$unit must symlink to ../$unit (relative)"
    done
done
! [ -e mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/initrd-fs.target.wants ] \
    || fail "initrd-fs.target.wants/ must NOT ship — initrd-fs.target is never activated in this initrd, so symlinks there are inert. Use initrd.target.wants/ instead."

# initrd-fs.target.d/50-myosi.conf was retired — initrd-fs.target is
# never activated in this initrd (nothing pulls it once sysroot-var.mount
# is gone), so a Requires= drop-in on it was dead code. Hard-fail
# semantics are now expressed via OnFailure=emergency.target on each
# unit in the chain.
! [ -e mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/initrd-fs.target.d ] \
    || fail "initrd-fs.target.d/ must NOT ship — initrd-fs.target is never activated in this initrd, so any drop-in on it is inert. Hard-fail is expressed via OnFailure=emergency.target on the chain units."
grep -qE '^ConditionDirectoryNotEmpty=!/sysroot/etc$' "$ETC_SEED_UNIT" \
    || fail "$ETC_SEED_UNIT must gate on ConditionDirectoryNotEmpty=!/sysroot/etc so it runs ONLY when the subvol is empty (first boot, or after operator wipe)"
grep -qE '^After=sysroot-etc\.mount$' "$ETC_SEED_UNIT" \
    || fail "$ETC_SEED_UNIT must order After=sysroot-etc.mount (subvol must be mounted before cp can populate it)"
grep -qE '^Wants=sysroot-etc.mount$' "$ETC_SEED_UNIT" \
    || fail "$ETC_SEED_UNIT must Wants=sysroot-etc.mount (Requires= would cascade-stop during the initrd-cleanup isolate; hard-fail comes from OnFailure=emergency.target)"
grep -qE '^OnFailure=emergency\.target$' "$ETC_SEED_UNIT" \
    || fail "$ETC_SEED_UNIT must set OnFailure=emergency.target so a failed seed drops to emergency rather than pivot into an empty /etc"
grep -qE '^Before=.*initrd\.target' "$ETC_SEED_UNIT" \
    || fail "$ETC_SEED_UNIT must order Before=initrd.target so initrd.target waits for this oneshot to complete before initrd-cleanup.service fires the isolate to initrd-switch-root.target"
grep -qE '^Before=.*initrd-switch-root\.target' "$ETC_SEED_UNIT" \
    || fail "$ETC_SEED_UNIT must order Before=initrd-switch-root.target (seed must finish before pivot so PID 1 sees populated /etc)"
grep -qE '^IgnoreOnIsolate=yes$' "$ETC_SEED_UNIT" \
    || fail "$ETC_SEED_UNIT must set IgnoreOnIsolate=yes (same chain-protection as sysroot-etc.mount + myosi-data-attach.service)"
grep -qE '^WantedBy=initrd\.target initrd-switch-root\.target$' "$ETC_SEED_UNIT" \
    || fail "$ETC_SEED_UNIT must declare WantedBy=initrd.target initrd-switch-root.target so [Install] matches the static .wants/ symlinks shipped under both target dirs"
grep -qE '^ExecStart=/usr/bin/cp -a --reflink=auto /sysroot/usr/share/factory/etc/\. /sysroot/etc/$' "$ETC_SEED_UNIT" \
    || fail "$ETC_SEED_UNIT must invoke 'cp -a --reflink=auto /sysroot/usr/share/factory/etc/. /sysroot/etc/' (factory seed)"
grep -qE '^ExecStart=/usr/bin/setfattr -n security\.selinux -v system_u:object_r:etc_t:s0 /sysroot/etc$' "$ETC_SEED_UNIT" \
    || fail "$ETC_SEED_UNIT must invoke 'setfattr etc_t /sysroot/etc' on the subvol root inode"
# data-attach.service dependency hygiene — same rules as the seed unit.
DATA_ATTACH_UNIT=mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/myosi-data-attach.service
grep -qE '^IgnoreOnIsolate=yes$' "$DATA_ATTACH_UNIT" \
    || fail "$DATA_ATTACH_UNIT must set IgnoreOnIsolate=yes so the initrd-cleanup isolate doesn't stop it (cascade-stops via Requires= don't propagate either, since upstream deps use Wants= not Requires=)"
grep -qE '^OnFailure=emergency\.target$' "$DATA_ATTACH_UNIT" \
    || fail "$DATA_ATTACH_UNIT must set OnFailure=emergency.target so a failed LUKS unlock / btrfs scan drops to emergency rather than continue to a doomed pivot"
grep -qE '^WantedBy=initrd\.target initrd-switch-root\.target$' "$DATA_ATTACH_UNIT" \
    || fail "$DATA_ATTACH_UNIT must declare WantedBy=initrd.target initrd-switch-root.target — [Install] must match the static .wants symlinks shipped under both target dirs"
! grep -qE 'Wants=systemd-repart\.service' "$DATA_ATTACH_UNIT" \
    && grep -qE 'Requires=systemd-repart' "$DATA_ATTACH_UNIT" && \
    fail "$DATA_ATTACH_UNIT must use Wants=systemd-repart.service NOT Requires= — Requires= cascades the stop when systemd-repart is stopped during the initrd-cleanup isolate"
true

# attr/setfattr is required in the initrd for myosi-etc-seed's
# subvol-root label step (cryptsetup + util-linux + btrfs-progs +
# coreutils cover the rest).
grep -qE '^[[:space:]]+attr$' mkosi.images/initrd/mkosi.conf \
    || fail "initrd must include the attr package so /usr/bin/setfattr is available for myosi-etc-seed.service"

# Declarative .mount unit for /sysroot/etc.
SYSROOT_ETC=mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/sysroot-etc.mount
[ -f "$SYSROOT_ETC" ] \
    || fail "$SYSROOT_ETC must ship — declarative /sysroot/etc mount on data-luks btrfs subvol=/etc (PID 1 needs /etc populated before unit graph generation, so this must fire in the initrd before pivot)"
grep -qE '^What=/dev/mapper/data$' "$SYSROOT_ETC" \
    || fail "$SYSROOT_ETC must mount /dev/mapper/data (the data-luks btrfs)"
grep -qE '^Type=btrfs$' "$SYSROOT_ETC" \
    || fail "$SYSROOT_ETC must specify Type=btrfs"
grep -qE '^IgnoreOnIsolate=yes$' "$SYSROOT_ETC" \
    || fail "$SYSROOT_ETC must set IgnoreOnIsolate=yes so initrd-cleanup's isolate to initrd-switch-root.target does not stop it before pivot"
grep -qE '^After=myosi-data-attach\.service$' "$SYSROOT_ETC" \
    || fail "$SYSROOT_ETC must order After=myosi-data-attach.service (LUKS unlock + btrfs scan must finish first)"
grep -qE '^Wants=myosi-data-attach.service$' "$SYSROOT_ETC" \
    || fail "$SYSROOT_ETC must Wants=myosi-data-attach.service (Requires= would cascade-stop during the initrd-cleanup isolate; hard-fail comes from OnFailure=emergency.target)"
grep -qE '^OnFailure=emergency\.target$' "$SYSROOT_ETC" \
    || fail "$SYSROOT_ETC must set OnFailure=emergency.target so a failed mount drops to emergency rather than pivot into an empty /etc"
grep -qE '^WantedBy=initrd\.target initrd-switch-root\.target$' "$SYSROOT_ETC" \
    || fail "$SYSROOT_ETC must declare WantedBy=initrd.target initrd-switch-root.target — [Install] must match the static .wants symlinks shipped under both target dirs"
grep -qE '^Before=.*myosi-etc-seed\.service' "$SYSROOT_ETC" \
    || fail "$SYSROOT_ETC must order Before=myosi-etc-seed.service so the seed unit runs against an already-mounted /sysroot/etc"
grep -qE '^Options=defaults,noatime,compress=zstd:3,subvol=/etc$' "$SYSROOT_ETC" \
    || fail "$SYSROOT_ETC must mount subvol=/etc with noatime + zstd:3 — /etc is a first-class persistent btrfs subvol, not an overlay"

# Explicit var.mount in main system — mirror of home.mount and srv.mount.
# Shadows gpt-auto-generator's emitted var.mount so /var lands with
# explicit subvol=/var + compress=zstd:3 (operator-mutable
# DefaultSubvolume + missing options aren't acceptable defaults).
VAR_MOUNT=mkosi.extra/usr/lib/systemd/system/var.mount
[ -f "$VAR_MOUNT" ] \
    || fail "$VAR_MOUNT must ship — explicit /var mount, shadows gpt-auto-generator's emitted var.mount so /var picks up subvol=/var + noatime + compress=zstd:3 (gpt-auto would mount /dev/mapper/data with btrfs defaults relying on DefaultSubvolume metadata)"
grep -qE '^What=/dev/mapper/data$' "$VAR_MOUNT" \
    || fail "$VAR_MOUNT must mount /dev/mapper/data (the data-luks btrfs)"
grep -qE '^Where=/var$' "$VAR_MOUNT" \
    || fail "$VAR_MOUNT must mount at /var"
grep -qE '^Type=btrfs$' "$VAR_MOUNT" \
    || fail "$VAR_MOUNT must specify Type=btrfs"
grep -qE '^Options=defaults,noatime,compress=zstd:3,subvol=/var$' "$VAR_MOUNT" \
    || fail "$VAR_MOUNT must mount subvol=/var with noatime + zstd:3 — identical Options= to home.mount and srv.mount"
grep -qE '^After=dev-mapper-data\.device$' "$VAR_MOUNT" \
    || fail "$VAR_MOUNT must order After=dev-mapper-data.device (mapper must exist before mount)"
grep -qE '^BindsTo=dev-mapper-data\.device$' "$VAR_MOUNT" \
    || fail "$VAR_MOUNT must BindsTo=dev-mapper-data.device (mapper down → mount torn down cleanly), same shape as home.mount + srv.mount"
grep -qE '^Before=local-fs\.target$' "$VAR_MOUNT" \
    || fail "$VAR_MOUNT must order Before=local-fs.target so tmpfiles-setup + journald see /var ready"
grep -qE '^WantedBy=local-fs\.target$' "$VAR_MOUNT" \
    || fail "$VAR_MOUNT must be WantedBy=local-fs.target"
grep -qE '^enable var\.mount$' mkosi.extra/usr/lib/systemd/system-preset/50-myosi.preset \
    || fail "50-myosi.preset must 'enable var.mount' so the static .wants/ symlink is created at build time"

# Explicit efi.mount — same shape as var.mount / home.mount / srv.mount.
# gpt-auto-generator fails entirely on verity-protected myosi installs
# (cmdline image_policy=:=ignore fallback excludes ESP and the
# root/usr-hash lookup fails on systemd 259), so /efi would never
# mount without this unit. Side effects of unmounted /efi:
#   * bootctl install/update/status — broken
#   * systemd-boot-random-seed.service — can't write
#     /efi/loader/random-seed
#   * sysupdate UKI transfer — "Read-only file system" because
#     /efi resolves against the verity-baked stub directory on /
EFI_MOUNT=mkosi.extra/usr/lib/systemd/system/efi.mount
[ -f "$EFI_MOUNT" ] \
    || fail "$EFI_MOUNT must ship — explicit /efi mount, ESP discovered by PARTLABEL=esp. Without it, gpt-auto-generator's failure on verity-protected installs leaves /efi unmounted and breaks bootctl / sysupdate UKI transfer / random-seed."
grep -qE '^What=/dev/disk/by-partlabel/esp$' "$EFI_MOUNT" \
    || fail "$EFI_MOUNT must mount /dev/disk/by-partlabel/esp (stable handle from repart's 00-esp.conf Label=esp)"
grep -qE '^Where=/efi$' "$EFI_MOUNT" \
    || fail "$EFI_MOUNT must mount at /efi"
grep -qE '^Type=vfat$' "$EFI_MOUNT" \
    || fail "$EFI_MOUNT must specify Type=vfat (ESP is FAT)"
grep -qE '^Options=defaults,umask=0077,shortname=winnt,discard,noatime$' "$EFI_MOUNT" \
    || fail "$EFI_MOUNT must use umask=0077,shortname=winnt,discard,noatime — umask=0077 restricts to root (boot secrets), discard+noatime keep the FS efficient"
grep -qE '^BindsTo=dev-disk-by\\x2dpartlabel-esp\.device$' "$EFI_MOUNT" \
    || fail "$EFI_MOUNT must BindsTo=dev-disk-by\\x2dpartlabel-esp.device so the mount tears down cleanly if the ESP device disappears"
grep -qE '^Before=local-fs\.target' "$EFI_MOUNT" \
    || fail "$EFI_MOUNT must order Before=local-fs.target"
grep -qE '^WantedBy=local-fs\.target$' "$EFI_MOUNT" \
    || fail "$EFI_MOUNT must be WantedBy=local-fs.target"
grep -qE '^enable efi\.mount$' mkosi.extra/usr/lib/systemd/system-preset/50-myosi.preset \
    || fail "50-myosi.preset must 'enable efi.mount' so the static .wants/ symlink is created at build time"

# tmpfiles myosi-etc-factory.conf retired. The `C! /etc - - - - /usr/share/factory/etc`
# rule's directory-level semantics don't actually solve the new-files-
# on-upgrade case (C only copies if target is missing/empty; once /etc
# is populated, C does nothing). The initrd's myosi-etc-seed.service
# is now the canonical and only seed mechanism.
! [ -e mkosi.extra/usr/lib/tmpfiles.d/myosi-etc-factory.conf ] \
    || fail "myosi-etc-factory.conf was retired — tmpfiles C! is directory-level (only fires when target is empty), so it can't propagate new factory files from /usr/share/factory/etc on image upgrades. myosi-etc-seed.service is the single seed path."
! grep -qE '^Type=overlay$' "$SYSROOT_ETC" \
    || fail "$SYSROOT_ETC must NOT be Type=overlay — the etc-subvol refactor replaced the overlayfs (lower=/usr/share/factory/etc + upper=/var/etc) with a real persistent btrfs subvolume"
! grep -vE '^\s*#' "$SYSROOT_ETC" \
    | grep -qE 'lowerdir|upperdir|workdir' \
    || fail "$SYSROOT_ETC must NOT carry overlayfs lower/upper/workdir options in active directives — the overlay was removed in the etc-subvol refactor (comments are fine)"

# repart.d/90-data.conf must materialize an /etc subvol on the data-luks
# btrfs at first-boot expansion. Without it sysroot-etc.mount fails on
# the very first boot (subvol=/etc doesn't exist yet).
REPART_DATA=mkosi.extra/usr/lib/repart.d/90-data.conf
grep -qE '^Subvolumes=/etc($|[[:space:],])' "$REPART_DATA" \
    || fail "$REPART_DATA must list /etc in Subvolumes= so first-boot repart creates the /etc subvol before sysroot-etc.mount fires"
grep -qE '^MakeDirectories=/etc($|[[:space:],])' "$REPART_DATA" \
    || fail "$REPART_DATA must include /etc in MakeDirectories= so the mountpoint inside the /var subvol exists"
! grep -qE '^MakeDirectories=/var/etc($|[[:space:],])' "$REPART_DATA" \
    || fail "$REPART_DATA must NOT pre-create /var/etc — that path was the retired overlay upperdir"
! grep -qE '^MakeDirectories=/var/\.etc-work($|[[:space:],])' "$REPART_DATA" \
    || fail "$REPART_DATA must NOT pre-create /var/.etc-work — that path was the retired overlay workdir"

# postinst-common.sh must NOT carry the /var/etc → /etc subs alias —
# that alias was for the overlay upperdir, which no longer exists.
! grep -qE '^[[:space:]]*echo "/var/etc /etc" >> "\$SUBS"$' mkosi.shared/postinst-common.sh \
    || fail "postinst-common.sh must NOT append /var/etc → /etc to file_contexts.subs — the /etc overlay was retired in the etc-subvol refactor, /var/etc has no targets to label"
# The /usr/share/factory/etc alias DOES stay — tmpfiles' C! copy from /usr/share/factory/etc to /etc
# benefits from labels matching at the source.
grep -qE '^[[:space:]]*echo "/usr/share/factory/etc /etc" >> "\$SUBS"$' mkosi.shared/postinst-common.sh \
    || fail "postinst-common.sh must keep /usr/share/factory/etc → /etc in file_contexts.subs so the C! tmpfiles copy lands etc_t-labeled in /etc"
# systemd-confext.service preset is left to Fedora defaults. We do NOT
# preset-disable it ourselves — operators who want confext later should
# be able to enable without our presets fighting them.
! grep -q '^disable systemd-confext\.service$' \
        mkosi.extra/usr/lib/systemd/system-preset/50-myosi.preset \
    || fail "50-myosi.preset must NOT carry an explicit `disable systemd-confext.service` line — leave the preset state at Fedora defaults so confext stays a future option"
# systemd-gpt-auto-generator stays UNMASKED. Validated on real
# hardware: it runs, emits redundant-but-correct units that never
# actually mount because initrd/main generated units take
# precedence. The "Cannot dissect image" log line we observed in VM
# testing was QEMU-specific (virtio-blk metadata gap) and does not
# reproduce on real hardware.
! grep -q 'ln -sfn /dev/null "\$BUILDROOT/etc/systemd/system-generators/systemd-gpt-auto-generator"' \
        mkosi.postinst \
    || fail "mkosi.postinst must NOT mask systemd-gpt-auto-generator — it's a useful fallback on real hardware; QEMU-only dissect warning doesn't justify the mask"
[ -x mkosi.extra/usr/libexec/myosi/sysext-baked-sync ] \
    || fail "sysext-baked-sync helper must ship at /usr/libexec/myosi/sysext-baked-sync and be executable"
grep -q '^SRC_DIR=/usr/share/myosi/extensions$' mkosi.extra/usr/libexec/myosi/sysext-baked-sync \
    || fail "sysext-baked-sync SRC_DIR must point at /usr/share/myosi/extensions (the verity-baked baseline location)"
grep -q '^TGT_DIR=/var/lib/extensions$' mkosi.extra/usr/libexec/myosi/sysext-baked-sync \
    || fail "sysext-baked-sync TGT_DIR must point at /var/lib/extensions (the path systemd-sysext actually scans)"
# Retired baseline-discovery drop-in (the one that tried to extend
# systemd-sysext's ConditionDirectoryNotEmpty to /usr/lib/extensions/)
# must not come back — verified empirically that adding /usr/lib/extensions
# to the condition fires the unit but doesn't make it scan that path.
! [ -e mkosi.extra/usr/lib/systemd/system/systemd-sysext.service.d/15-myosi-include-usr-lib-extensions.conf ] \
    || fail "15-myosi-include-usr-lib-extensions.conf was retired — systemd-sysext does not discover from /usr/lib/extensions/, the symlink-sync model replaced it"
# Retired fleet-keys sysupdate transfer must not return: fleet-keys is
# image-coupled (built from this repo, ships only with image swap), no
# operator-side update path exists.
! [ -e mkosi.extra/usr/lib/sysupdate.extensions.d/37-fleet-keys.transfer ] \
    || fail "37-fleet-keys.transfer was retired — fleet-keys is image-coupled (no independent sysupdate rotation)"
! [ -e mkosi.extra/usr/lib/sysupdate.extensions.d/fleet-keys.feature ] \
    || fail "fleet-keys.feature was retired — fleet-keys has no separate sysupdate feature"

# Sysext-introduced groups (libvirt, incus-admin) must NOT be
# pre-declared in base sysusers — each sysext's own sysusers.d ships
# the group definition and our systemd-sysext.service ExecStartPost
# replay calls systemd-sysusers to pick it up. The default user is
# bound to those groups at runtime by /usr/libexec/myosi/homed-bind-
# sysext-groups (gpasswd -a writes to /etc/group), so base hosts have
# a clean group set and only get the sysext groups when those sysexts
# are actually enabled.
! grep -qE '^g libvirt\s' mkosi.extra/usr/lib/sysusers.d/myosi-groups.conf \
    || fail "myosi-groups.conf must NOT pre-declare libvirt — the virt sysext's own sysusers.d creates it; myosi-homed-user@ binds user at runtime"
! grep -qE '^g incus-admin\s' mkosi.extra/usr/lib/sysusers.d/myosi-groups.conf \
    || fail "myosi-groups.conf must NOT pre-declare incus-admin — the containers sysext's own sysusers.d creates it; myosi-homed-user@ binds user at runtime"
# Declarative user identity at /usr/share/myosi/users/<name>.user.
# Mirrors v15.13 working layout: identity-only JSON; password +
# storage backend + disk size are CLI flags on homectl create in
# homed-user-provision (Fedora 44 systemd 259 does NOT process the
# secret section of --identity=, so the credstore home.create.<name>
# pattern silently fails to seed the LUKS keyslot).
USER_RECORD=mkosi.extra/usr/share/myosi/users/user.user
[ -f "$USER_RECORD" ] \
    || fail "$USER_RECORD must ship — declarative source of truth for the default user record (homectl create --identity=)"
grep -q '"userName": "user"' "$USER_RECORD" \
    || fail "$USER_RECORD must set userName=user"
grep -q '"uid": 1000' "$USER_RECORD" \
    || fail "$USER_RECORD must pin uid=1000"
! grep -q 'hashedPassword' "$USER_RECORD" \
    || fail "$USER_RECORD must NOT carry hashedPassword — providing one in the identity makes homectl create record it AS-IS instead of deriving a fresh hash + LUKS keyslot from NEWPASSWORD. Empirically (2026.06.19.06 QEMU) that path leaves the LUKS keyslot unseeded so getty/PAM password auth fails. Let homectl derive both hash and keyslot from the PASSWORD/NEWPASSWORD env vars seeded by homed-user-provision."
! grep -qE '^\s*"(libvirt|incus-admin)"' "$USER_RECORD" \
    || fail "$USER_RECORD must NOT list sysext-introduced groups in memberOf — homed evaluates memberOf once at home activation; runtime binding via myosi-homed-user@ handles sysext groups"
! grep -qi 'tpm2' "$USER_RECORD" \
    || fail "$USER_RECORD must not require TPM2 for the default user home"
! grep -q '"secret"\|"storage"\|"diskSize"\|"luksExtraMountOptions"' "$USER_RECORD" \
    || fail "$USER_RECORD must NOT carry secret/storage/diskSize/luksExtraMountOptions — those are CLI flags on homectl create (F44 systemd 259 ignores them in --identity=)"
grep -q '^root:\$6\$myosiuserinit\$hny4TLIXPUZT6aYu\.cwc4VV739dLI1Zv0e2fGZ1Fy/LpbshfPoxXYueIUMlrTyi1/YrxZgM8Djqogbwa0rKu2\.::0:99999:7:::$' mkosi.extra/etc/shadow \
    || fail "root must keep the default changeme password for console debugging until the operator changes it"
# homed-user-provision script — combined create + bind, used by the
# myosi-homed-user@.service template.
PROVISION=mkosi.extra/usr/libexec/myosi/homed-user-provision
[ -x "$PROVISION" ] \
    || fail "$PROVISION helper must ship and be executable"
grep -q '^set -euo pipefail$' "$PROVISION" \
    || fail "$PROVISION must fail fast if homectl create fails (set -euo pipefail)"
grep -q 'PASSWORD="\$BOOTSTRAP_PASSWORD" NEWPASSWORD="\$BOOTSTRAP_PASSWORD"' "$PROVISION" \
    || fail "$PROVISION must feed PASSWORD + NEWPASSWORD env vars — homectl acquire_existing_password / acquire_new_password seed the LUKS keyslot from these on F44 systemd 259"
grep -q -- '--luks-extra-mount-options=defcontext=system_u:object_r:user_home_dir_t:s0' "$PROVISION" \
    || fail "$PROVISION must pass --luks-extra-mount-options=defcontext=user_home_dir_t — without it inner-LUKS-btrfs files end up unlabeled_t and SELinux denies sudo/sshd/dbus reads"
grep -q -- '--storage=luks' "$PROVISION" \
    || fail "$PROVISION must select LUKS storage — defence in depth on top of data-luks and symmetric upgrade path for TPM2 enrolment"
grep -q '^DROP_DIR=/usr/share/myosi/user-groups.d$' "$PROVISION" \
    || fail "$PROVISION must read groups from /usr/share/myosi/user-groups.d/ drop-in dir (decoupled from base)"
! grep -qE '^SYSEXT_OWNED_GROUPS=' "$PROVISION" \
    || fail "$PROVISION must NOT carry a hardcoded SYSEXT_OWNED_GROUPS array — use the drop-in dir instead"
! grep -q 'myosi-homed-debug\|tee -a\|DEBUG:' "$PROVISION" \
    || fail "$PROVISION must not ship temporary VM debug logging"
# Templated service unit — one instance per user.
USER_UNIT=mkosi.extra/usr/lib/systemd/system/myosi-homed-user@.service
[ -f "$USER_UNIT" ] \
    || fail "$USER_UNIT must ship — templated provisioning unit, one instance per user"
grep -q '^ExecStart=/usr/libexec/myosi/homed-user-provision %i$' "$USER_UNIT" \
    || fail "$USER_UNIT must call homed-user-provision with %i (the instance username)"
grep -qE '^StandardError=(journal\+console|inherit)' "$USER_UNIT" \
    || fail "$USER_UNIT must route StandardError to console — ExecStartPost-on-homed swallowed first-boot failures because stderr went to journal only"
grep -q '^After=systemd-homed.service' "$USER_UNIT" \
    || fail "$USER_UNIT must order After=systemd-homed.service so the homed varlink interface is up before homectl create is invoked"
grep -q '^WantedBy=multi-user.target$' "$USER_UNIT" \
    || fail "$USER_UNIT must be WantedBy=multi-user.target"
# Static .wants/ symlink for the default user instance. `systemctl
# preset-all` (run during postinst) does NOT honor template-instance
# enables in *.preset files — it walks unit files on disk and skips
# template units. Without this symlink the unit ships but never
# activates on first boot.
USER_WANTS=mkosi.extra/usr/lib/systemd/system/multi-user.target.wants/myosi-homed-user@user.service
[ -L "$USER_WANTS" ] \
    || fail "$USER_WANTS must be a static .wants/ symlink — preset-all skips template-instance enables, this is the image-baked enable for the default user instance"
[ "$(readlink "$USER_WANTS")" = "../myosi-homed-user@.service" ] \
    || fail "$USER_WANTS must point at ../myosi-homed-user@.service (relative)"
grep -q '^DefaultInstance=user$' "$USER_UNIT" \
    || fail "$USER_UNIT must set DefaultInstance=user so a bare \`systemctl enable myosi-homed-user@.service\` activates the default user"
# Base image must NOT ship any user-groups.d snippet — feature
# coupling lives in the sysext / profile mkosi.extra, not in base.
! [ -d mkosi.extra/usr/share/myosi/user-groups.d ] \
    || fail "base mkosi.extra must NOT ship /usr/share/myosi/user-groups.d — sysext / profile mkosi.extra owns those snippets"
# Each feature ships its snippet ONLY from its profile mkosi.extra.
# The matching sysext sub-image pulls the same tree via
# `ExtraTrees=../../mkosi.profiles/<feat>/mkosi.extra:/` in its
# mkosi.conf, so the snippet ships in BOTH bake paths from a SINGLE
# source. Duplicating into mkosi.images/<feat>/mkosi.extra is wrong
# — divergence between the two copies is silent until the sysext
# and profile builds disagree at runtime.
for feat in virt containers; do
    grep -qx "$([ "$feat" = virt ] && echo libvirt || echo incus-admin)" \
            "mkosi.profiles/${feat}/mkosi.extra/usr/share/myosi/user-groups.d/50-${feat}.conf" \
        || fail "${feat} profile must ship usr/lib/myosi/user-groups.d/50-${feat}.conf — sysext pulls the same tree via ExtraTrees"
    ! [ -e "mkosi.images/${feat}/mkosi.extra/usr/share/myosi/user-groups.d/50-${feat}.conf" ] \
        || fail "${feat} sysext mkosi.extra must NOT duplicate 50-${feat}.conf — single source is mkosi.profiles/${feat}/mkosi.extra, pulled in via ExtraTrees"
done
# systemd-homed.service must NOT ship a drop-in that wires user
# provisioning into ExecStartPost — that pattern silently swallowed
# first-boot failures because homed is Type=notify (READY=1 fires
# before ExecStartPost runs) and ExecStartPost stderr only reaches
# the journal, not the console. Provisioning lives in its own
# templated unit instead.
! [ -e mkosi.extra/usr/lib/systemd/system/systemd-homed.service.d ] \
    || fail "systemd-homed.service.d must not exist — user provisioning is decoupled into myosi-homed-user@.service to avoid Type=notify masking failures"
# Preset must enable the default user's instance so first boot
# materializes the home without operator intervention.
grep -q '^enable myosi-homed-user@user\.service$' \
        mkosi.extra/usr/lib/systemd/system-preset/50-myosi.preset \
    || fail "50-myosi.preset must enable myosi-homed-user@user.service so the default user is provisioned on first boot"
# refresh_sysext in lib.sh must trigger the template so live sysext
# enables (sudo myosi extension-enable virt) bind the user without a
# reboot. `systemctl start` re-runs the oneshot (RemainAfterExit=no)
# and the create phase no-ops via homectl inspect once the user exists.
grep -q 'systemctl start myosi-homed-user@user\.service' mkosi.extra/usr/libexec/myosi/lib.sh \
    || fail "refresh_sysext must start myosi-homed-user@user.service so live extension-enable rebinds sysext-introduced group memberships"

# Sysctl modernization — kernel-removed knobs must not appear, and
# nf_conntrack must load before sysctl applies nf_conntrack_max.
SYSCTL=mkosi.extra/usr/lib/sysctl.d/50-myosi-performance.conf
! grep -vE '^\s*#' "$SYSCTL" | grep -qE 'kernel\.sched_(latency|min_granularity|wakeup_granularity)_ns' \
    || fail "EEVDF-era kernels removed CFS scheduler sysctls — they must not be configured (writes log No such file or directory at every boot)"
! grep -vE '^\s*#' "$SYSCTL" | grep -q 'kernel\.unprivileged_userns_clone' \
    || fail "kernel.unprivileged_userns_clone was removed in Linux 5.10+ — must not be configured"
grep -q '^net.netfilter.nf_conntrack_max' "$SYSCTL" \
    || fail "nf_conntrack_max sysctl must be set (or this assertion updated if intentionally removed)"
CONNTRACK=mkosi.extra/usr/lib/modules-load.d/50-myosi-conntrack.conf
[ -f "$CONNTRACK" ] \
    || fail "$CONNTRACK must ship so nf_conntrack is loaded before sysctl applies nf_conntrack_max"
grep -q '^nf_conntrack$' "$CONNTRACK" \
    || fail "$CONNTRACK must request the nf_conntrack module"

# /srv is a first-class btrfs subvolume on data-luks, not a symlink
# into /var. The sealed root must contain a real /srv mountpoint, and
# srv.mount mounts the subvolume before local-fs.target.
! grep -qE 'ln -s var/srv[[:space:]]+"\$BUILDROOT/srv"' mkosi.shared/postinst-common.sh \
    || fail "postinst must not symlink /srv -> var/srv; /srv is mounted as its own btrfs subvolume"
grep -q 'mkdir -p "\$BUILDROOT/srv"' mkosi.shared/postinst-common.sh \
    || fail "postinst must create a real /srv mountpoint in the sealed root"
[ -f mkosi.extra/usr/lib/systemd/system/srv.mount ] \
    || fail "srv.mount must ship so /srv is mounted from the data-luks btrfs subvolume"
grep -q '^Options=defaults,noatime,compress=zstd:3,subvol=/srv$' mkosi.extra/usr/lib/systemd/system/srv.mount \
    || fail "srv.mount must use noatime, zstd:3, and subvol=/srv"

# NVIDIA cdi-refresh rate-limit drop-in: the path watcher fires twice per
# depmod refresh (modules.dep + modules.dep.bin), triggering the default
# 5-starts-in-10s limit even though every individual run completes
# successfully. Drop-in disables the limit. Mirrored for both branches.
for branch in nvidia nvidia-580xx; do
    f="mkosi.images/${branch}/mkosi.extra/usr/lib/systemd/system/nvidia-cdi-refresh.service.d/10-myosi-no-rate-limit.conf"
    [ -f "$f" ] \
        || fail "$branch must ship nvidia-cdi-refresh rate-limit drop-in at $f"
    grep -q '^StartLimitIntervalSec=0$' "$f" \
        || fail "$branch nvidia-cdi-refresh drop-in must set StartLimitIntervalSec=0"
done

# Verity-sig sysupdate transfer must carry ProtectVersion=%A for
# symmetry with 10-root.transfer and 11-verity.transfer — without it,
# sysupdate can overwrite the active sig partition while the kernel
# still holds it pinned, breaking verify on the next boot.
grep -q '^ProtectVersion=%A$' mkosi.extra/usr/lib/sysupdate.d/12-verity-sig.transfer \
    || fail "12-verity-sig.transfer must set ProtectVersion=%A so the active sig slot is never overwritten"

# "Run-once" completion markers live under /var/lib/myosi/.marks/ as
# <task>.done files, one per oneshot. Naming convention:
#
#   * task name = service basename minus the `myosi-` prefix (if any)
#                 and the `.service` suffix.
#   * mark file = `<task>.done`
#
# Examples:
#   myosi-firstboot-relabel.service -> firstboot-relabel.done
#   flatpak-setup.service           -> flatpak-setup.done
#
# Enforces single-greppable namespace AND keeps the mark name aligned
# with the owning service so operator inspection of /var/lib/myosi/
# .marks/ trivially traces back to "what service produced this?".
#
# Any other ConditionPathExists= pattern (loose dotfiles in
# /var/lib/myosi/, ad-hoc suffix conventions) is a regression.
mapfile -t marker_paths < <(grep -rhEo 'ConditionPathExists=!?/var/lib/myosi/[^[:space:]]+' \
    mkosi.extra mkosi.images mkosi.profiles 2>/dev/null | sort -u)
for raw in "${marker_paths[@]}"; do
    path="${raw#ConditionPathExists=}"
    path="${path#!}"
    case "$path" in
        /var/lib/myosi/.marks/*.done) : ok ;;
        *) fail "marker convention violation: $raw — markers must live at /var/lib/myosi/.marks/<task>.done" ;;
    esac
done

# Mark filename must match its owning service's task name. Walks every
# service that mentions /var/lib/myosi/.marks/<X>.done, extracts <X>,
# and asserts it equals the service basename (stripped of myosi- prefix
# and .service suffix).
while IFS= read -r service_file; do
    [ -f "$service_file" ] || continue
    mark=$(grep -oE '/var/lib/myosi/\.marks/[A-Za-z0-9_-]+\.done' "$service_file" \
        | head -1 | sed 's|.*/||; s|\.done$||')
    [ -n "$mark" ] || continue
    svc_basename=$(basename "$service_file" .service)
    expected_mark=${svc_basename#myosi-}
    if [ "$mark" != "$expected_mark" ]; then
        fail "mark name '$mark' in $service_file must equal task name '$expected_mark' (service basename minus 'myosi-' prefix + '.service' suffix)"
    fi
done < <(grep -rlE '/var/lib/myosi/\.marks/[A-Za-z0-9_-]+\.done' \
    mkosi.extra mkosi.images mkosi.profiles 2>/dev/null \
    | grep -E '\.service$')
grep -q '^d /var/lib/myosi/.marks ' mkosi.extra/usr/lib/tmpfiles.d/myosi.conf \
    || fail "tmpfiles.d/myosi.conf must declare /var/lib/myosi/.marks so the marker dir exists before any oneshot tries to touch into it"

# sysupdate is invoked through a short PATH command (`sysupdate`), backed
# by a symlink at /usr/local/bin/sysupdate -> /usr/lib/systemd/systemd-
# sysupdate. The binary path avoids the systemd-sysupdated SELinux gap
# on Fedora 44; the symlink keeps recipes/operators from typing the
# absolute /usr/lib/systemd path. Easy to flip back to updatectl when
# selinux-policy catches up (MYOSI_SYSUPDATE_BIN env override + a few
# argument-form tweaks in 00-update.just / 10-extensions.just).
[ -L mkosi.extra/usr/local/bin/sysupdate ] \
    || fail "/usr/local/bin/sysupdate must ship as a symlink so operators don't type /usr/lib/systemd/systemd-sysupdate"
[ "$(readlink mkosi.extra/usr/local/bin/sysupdate)" = "/usr/lib/systemd/systemd-sysupdate" ] \
    || fail "sysupdate symlink must point at /usr/lib/systemd/systemd-sysupdate"
grep -q 'MYOSI_SYSUPDATE_BIN:-sysupdate' mkosi.extra/usr/libexec/myosi/lib.sh \
    || fail "sysupdate_env default must be the short \`sysupdate\` command (PATH-resolved via /usr/local/bin/sysupdate)"

# refresh_sysext must NOT try to restart the retired myosi-depmod.service.
# sysext-modules-refresh is now invoked as ExecStartPost of systemd-sysext.service,
# so `systemd-sysext refresh` triggers it automatically — no separate
# restart needed.
! grep -q 'systemctl restart myosi-depmod\.service' mkosi.extra/usr/libexec/myosi/lib.sh \
    || fail "refresh_sysext must not restart retired myosi-depmod.service — replay is wired into systemd-sysext.service ExecStartPost"
grep -q 'systemctl restart myosi-glib-schemas-compile.service' mkosi.extra/usr/libexec/myosi/lib.sh \
    || fail "refresh_sysext must restart myosi-glib-schemas-compile.service after sysext refresh"
# The glib schemas service runs in multi-user.target slot — explicit
# DefaultDependencies=no + Before=basic.target was attempted but closed
# an ordering cycle through systemd-sysext.service's mount dependencies.
# Asserts the cycle-free shape.
! grep -q '^DefaultDependencies=no$' mkosi.extra/usr/lib/systemd/system/myosi-glib-schemas-compile.service \
    || fail "myosi-glib-schemas-compile.service must NOT set DefaultDependencies=no — closes a cycle via /usr mount deps; rely on default sysinit ordering instead"
! grep -q '^RequiresMountsFor=' mkosi.extra/usr/lib/systemd/system/myosi-glib-schemas-compile.service \
    || fail "myosi-glib-schemas-compile.service must NOT set RequiresMountsFor=/usr/* — After=systemd-sysext.service already guarantees the merge; the mount dep was the cycle source"
! grep -q '^Before=.*basic.target' mkosi.extra/usr/lib/systemd/system/myosi-glib-schemas-compile.service \
    || fail "myosi-glib-schemas-compile.service must NOT order Before=basic.target — combined with default sysinit ordering it creates a cycle. multi-user slot via Install: WantedBy=multi-user.target is the right home."
grep -q '^WantedBy=multi-user.target$' mkosi.extra/usr/lib/systemd/system/myosi-glib-schemas-compile.service \
    || fail "myosi-glib-schemas-compile.service must be wanted by multi-user.target (only user sessions consume GSETTINGS_SCHEMA_DIR)"
grep -q '^Before=systemd-user-sessions.service' mkosi.extra/usr/lib/systemd/system/myosi-glib-schemas-compile.service \
    || fail "myosi-glib-schemas-compile.service must finish before systemd-user-sessions.service so logins see the cache"
# DBus + polkit must be reloaded so sysext-shipped DBus activation
# files (e.g. desktop sysext ships org.freedesktop.Flatpak.SystemHelper)
# become visible without a reboot. Verified failure: `flatpak install`
# right after `sudo myosi extension-enable desktop` errored with
# "The name is not activatable" until dbus-broker.service was reloaded.
grep -q 'reload dbus-broker.service' mkosi.extra/usr/libexec/myosi/lib.sh \
    || fail "refresh_sysext must reload dbus-broker.service so sysext-shipped DBus services become activatable without a reboot"
grep -q 'reload polkit.service' mkosi.extra/usr/libexec/myosi/lib.sh \
    || fail "refresh_sysext must reload polkit.service so sysext-shipped policy rules take effect without a reboot"
# ldconfig must refresh after sysext merge — sysexts that ship libraries
# in non-default paths (Fedora's pipewire-jack ships libjack.so.0 under
# /usr/lib64/pipewire-0.3/jack/ via the /usr/lib/ld.so.conf.d/ entry from
# the desktop sysext) need the ld.so cache rebuilt for the new search
# dirs to take effect. Observed failure: waybar refused to launch under
# niri with "libjack.so.0: cannot open shared object file" until
# ldconfig ran.
grep -qE '^\s*ldconfig\b' mkosi.extra/usr/libexec/myosi/lib.sh \
    || fail "refresh_sysext must run ldconfig so sysext-shipped libraries in non-default paths are discoverable without a reboot"
[ -f mkosi.profiles/desktop/mkosi.extra/usr/lib/ld.so.conf.d/00-myosi-pipewire-jack.conf ] \
    || fail "desktop profile must ship /usr/lib/ld.so.conf.d/00-myosi-pipewire-jack.conf so libjack.so.0 (in /usr/lib64/pipewire-0.3/jack) is on the linker search path"

# sysext_extension_release_path must write the file at the arch-
# suffixed path that systemd-sysext actually reads at merge time.
# systemd looks up extension-release.<imageid>_<imageversion>_<arch>
# matching the .raw image's filename (Output=%i_%v_%a) — without the
# _<arch> suffix mkosi creates a second file alongside ours, systemd
# reads mkosi's auto-generated stub (no EXTENSION_RELOAD_MANAGER, no
# extra fields), our extras are silently ignored, and sysext drop-ins
# that need a manager reload (Upholds= on multi-user.target.d/...)
# never fire. Verified empirically on 2026.06.19.23: with the no-arch
# path, our EXTENSION_RELOAD_MANAGER=1 landed in the dead file and
# desktop+nvidia Upholds= didn't activate at first boot.
grep -q 'extension-release\.%s_%s_%s' mkosi.shared/sysext-build.sh \
    || fail "sysext_extension_release_path must write to extension-release.<name>_<version>_<arch> so mkosi finds it and systemd reads OUR file (not mkosi's auto-generated stub without our directives)"
grep -q 'sysext_arch()' mkosi.shared/sysext-build.sh \
    || fail "sysext-build.sh must expose sysext_arch() so the architecture token used in the extension-release path matches what mkosi exports via ARCHITECTURE= / MKOSI_ARCHITECTURE= (no hardcoded x86-64)"
! grep -qE "printf 'ARCHITECTURE=x86-64" mkosi.shared/sysext-build.sh \
    || fail "sysext_write_extension_release must NOT hardcode ARCHITECTURE=x86-64 — use sysext_arch() so arm64 builds get the right token"
# EXTENSION_RELOAD_MANAGER=1 must live INSIDE sysext_write_extension_release,
# not as a duplicated arg at every callsite. Centralising guarantees no
# future sysext gets shipped without the directive — that was the
# regression that swallowed Upholds= drop-ins on desktop+nvidia.
grep -qE "printf 'EXTENSION_RELOAD_MANAGER=1" mkosi.shared/sysext-build.sh \
    || fail "sysext_write_extension_release must emit EXTENSION_RELOAD_MANAGER=1 unconditionally so every sysext triggers a manager reload at merge time"
! grep -rqE 'sysext_write_extension_release\s+\S+\s+.*EXTENSION_RELOAD_MANAGER=1' mkosi.shared/ mkosi.images/ 2>/dev/null \
    || fail "sysext_write_extension_release callers must NOT pass EXTENSION_RELOAD_MANAGER=1 — the helper sets it. Drop the duplicate arg."

# Audio: pipewire user units must be auto-enabled for every login user.
# Activation moved from imperative sysext_uphold_user_units postinst
# helpers to declarative Upholds= target drop-ins shipped directly in
# the profile's mkosi.extra/ — same effect, simpler shape, survives
# sysext-merge cleanly because /usr/lib/systemd/user/*.d/ drop-ins are
# part of the verity-baked tree.
DESKTOP_USER_DROPIN=mkosi.profiles/desktop/mkosi.extra/usr/lib/systemd/user/default.target.d/50-myosi-desktop.conf
[ -f "$DESKTOP_USER_DROPIN" ] \
    || fail "desktop profile must ship $DESKTOP_USER_DROPIN to Upholds= the user-scope audio + session manager"
grep -q '^Upholds=' "$DESKTOP_USER_DROPIN" \
    || fail "$DESKTOP_USER_DROPIN must declare Upholds= for user services (pipewire/wireplumber)"
# Belt-and-suspenders: forbid the raw user-target.wants/ symlinks that
# were briefly shipped. Upholds= drop-in pattern replaced them.
! [ -e mkosi.images/desktop/mkosi.extra/usr/lib/systemd/user/sockets.target.wants ] \
    || fail "desktop sysext must NOT ship /usr/lib/systemd/user/sockets.target.wants/ symlinks — use Upholds= drop-ins"
! [ -e mkosi.images/desktop/mkosi.extra/usr/lib/systemd/user/default.target.wants ] \
    || fail "desktop sysext must NOT ship /usr/lib/systemd/user/default.target.wants/ symlinks — use Upholds= drop-ins"
! [ -e mkosi.profiles/desktop/mkosi.extra/usr/lib/systemd/user/sockets.target.wants ] \
    || fail "desktop profile must NOT ship /usr/lib/systemd/user/sockets.target.wants/ symlinks — use Upholds= drop-ins"
! [ -e mkosi.profiles/desktop/mkosi.extra/usr/lib/systemd/user/default.target.wants ] \
    || fail "desktop profile must NOT ship /usr/lib/systemd/user/default.target.wants/ symlinks — use Upholds= drop-ins"

# virt sysext must NOT reference sysext-load-selinux@virt.service — that
# unit does not exist anywhere in the codebase or upstream systemd. It
# was inherited from an early design that did `semodule -i virt.pp.bz2`
# at sysext merge time, before we settled on baked xattrs (mkfs.erofs
# --file-contexts=) as the primary mechanism. virt's SELinux types are
# already in Fedora's selinux-policy-targeted (base), no runtime
# module load needed.
# Filter shell comments before grepping — the rationale block in the
# updated postinst documents what was removed and why, which would
# match the regex if we didn't strip comment lines first.
! grep -vE '^\s*#' mkosi.images/virt/mkosi.postinst \
    | grep -q 'sysext-load-selinux' \
    || fail "virt/mkosi.postinst must NOT reference sysext-load-selinux@virt.service in code (comments OK) — that unit does not exist; virt SELinux types live in base policy via selinux-policy-targeted"

# Desktop theme + Wayland env vars ship via /usr/lib/environment.d/
# inside the desktop sysext. systemd --user reads this dir at user
# session start; without these vars Chrome/Electron run on XWayland
# (ignoring niri's prefer-no-csd) and Qt apps draw their own CSD.
# Verified on externy 2026-06-08: title bars visible on Chrome until
# the env file was dropped + niri prefer-no-csd uncommented.
[ -f mkosi.profiles/desktop/mkosi.extra/usr/lib/environment.d/50-myosi-theme.conf ] \
    || fail "desktop profile must ship /usr/lib/environment.d/50-myosi-theme.conf so Qt/GTK/Electron pick correct Wayland + theme defaults per login user"
grep -q '^ELECTRON_OZONE_PLATFORM_HINT=auto' mkosi.profiles/desktop/mkosi.extra/usr/lib/environment.d/50-myosi-theme.conf \
    || fail "50-myosi-theme.conf must set ELECTRON_OZONE_PLATFORM_HINT=auto so Chrome/Electron prefer Wayland over XWayland"
grep -q '^QT_WAYLAND_DISABLE_WINDOWDECORATION=1' mkosi.profiles/desktop/mkosi.extra/usr/lib/environment.d/50-myosi-theme.conf \
    || fail "50-myosi-theme.conf must set QT_WAYLAND_DISABLE_WINDOWDECORATION=1 so Qt apps skip CSD under niri"

# The .ko.xz recompress step must use kernel-xz-compatible options
# (single block, 1 MiB dict, CRC32). Default `xz` produces multi-block
# 8 MiB-dict CRC64 streams that the kernel xz_dec rejects with
# XZ_BUF_ERROR (status 6, surfaced as `decompression failed with status
# 6` + modprobe `Invalid argument`).
grep -q -- '--lzma2=dict=1MiB --check=crc32' mkosi.shared/kmod-build.sh \
    || fail "kmod-build.sh must use --lzma2=dict=1MiB --check=crc32 when recompressing .ko.xz (kernel xz_dec compat)"

# UnifiedKernelImageFormat must use config-parse-time %v, not the
# nonexistent delayed &v specifier — see mkosi v26 source
# expand_kernel_specifiers (only e/k/h are defined). The bug produced
# UKI files named `myosi_.efi` on the 2026.06.06.02 release.
grep -q '^UnifiedKernelImageFormat=%i_%v_%a$' mkosi.conf \
    || fail "mkosi.conf UnifiedKernelImageFormat must use %i_%v_%a (arch in name matches every other Output=%i_%v_%a artifact)"

# TPM2 enrollment is bound to stable trust anchors, not the raw UKI
# measurement. PCR 11 changes on every UKI update and would force
# passphrase fallback + re-enrollment on headless hosts. PCR 7 covers
# Secure Boot policy/db state; PCR 14 covers shim/MOK policy/certs.
grep -q '^SignExpectedPcr=no$' mkosi.conf \
    || fail "mkosi.conf must keep SignExpectedPcr=no until the release pipeline has a TPM-backed signing path"
grep -q -- '--tpm2-pcrs=7+14' README.md \
    || fail "README must document TPM2 enrollment binding to stable PCRs 7+14, not UKI-specific PCR 11"
! grep -R -q -- '--tpm2-pcrs=7+11' README.md mkosi.extra \
    || fail "shipped myosi docs/configs must not bind TPM2 enrollment to PCR 11 directly because UKI updates change it"

# Single disk-layout path — seed image + first-boot expansion
# (ParticleOS pattern). The shipped .raw.zst carries 4 partitions (ESP +
# root-A + verity-A + verity-sig-A); the initrd expands to 8 on first
# boot.
#
# mkosi.repart/                       auto-discovered by mkosi at build time —
#                                     4 confs only
# mkosi.extra/usr/lib/repart.d/       baked into the deployed root and copied
#                                     into the initrd — 8 confs including the
#                                     build set plus root-B + verity-B +
#                                     verity-sig-B + data-luks
#
# mkosi.conf MUST NOT carry RepartDirectories= (auto-discovery handles
# the build set). mkosi.conf carries ONLY the bootable minimum (main
# rootfs + initrd + fleet-keys). All optional Profiles + Dependencies
# (containers, virt, desktop, nvidia, mybox) live in mkosi.local.conf
# so per-host overrides and qemu testing flags ship together with
# the fleet baseline in a single uncommitted, host-specific file.
! grep -qE '^RepartDirectories=' mkosi.conf \
    || fail "mkosi.conf must NOT set RepartDirectories= — mkosi.repart/ is auto-discovered as the build-time layout"
! grep -qE '^Profiles=' mkosi.conf \
    || fail "mkosi.conf must NOT bake Profiles= — Profiles=containers / Profiles=virt belong in mkosi.local.conf so the committed file stays uniform"
for dep in initrd fleet-keys; do
    grep -qE "^Dependencies=${dep}$" mkosi.conf \
        || fail "mkosi.conf must build the minimum dependency image: ${dep}"
done
for dep in desktop nvidia mybox; do
    ! grep -qE "^Dependencies=${dep}$" mkosi.conf \
        || fail "mkosi.conf must NOT carry optional Dependencies=${dep} — it belongs in mkosi.local.conf"
done
! [ -f mkosi.conf.d/90-profile-minimal.conf ] \
    || fail "mkosi.conf.d/90-profile-minimal.conf must not exist — the old minimal profile selector was retired"

# Build set: only the 4 confs that go into the shipped .raw.
for f in 00-esp.conf 10-root-a-verity-sig.conf 11-root-a-verity.conf 12-root-a.conf; do
    [ -f "mkosi.repart/$f" ] \
        || fail "mkosi.repart/$f missing — needed for the bootable shipped image"
done
for f in 20-root-b-verity-sig.conf 21-root-b-verity.conf 22-root-b.conf 90-data.conf; do
    ! [ -e "mkosi.repart/$f" ] \
        || fail "mkosi.repart/$f must NOT exist — first-boot repart creates this from mkosi.extra/usr/lib/repart.d copied into the initrd"
done

# Runtime set: 8 confs (build set + 4 first-boot-created partitions).
# The first 4 must preserve the same Type=/Label= identity as the build
# set so first-boot repart matches existing partitions. Other settings
# may differ: build-time root uses CopyFiles=/ + Minimize=, while runtime
# files describe steady-state shape/growth.
RUNTIME_REPART=mkosi.extra/usr/lib/repart.d
for f in 00-esp.conf 10-root-a-verity-sig.conf 11-root-a-verity.conf 12-root-a.conf \
         20-root-b-verity-sig.conf 21-root-b-verity.conf 22-root-b.conf 90-data.conf; do
    [ -f "$RUNTIME_REPART/$f" ] \
        || fail "$RUNTIME_REPART/$f missing — needed for first-boot expansion"
done
for f in 00-esp.conf 10-root-a-verity-sig.conf 11-root-a-verity.conf 12-root-a.conf; do
    for key in Type Label; do
        value=$(grep -E "^${key}=" "mkosi.repart/$f" || true)
        [ -n "$value" ] || continue
        grep -qxF "$value" "$RUNTIME_REPART/$f" \
            || fail "$RUNTIME_REPART/$f must preserve $value from mkosi.repart/$f so first-boot repart matches the existing partition"
    done
done

# Runtime repart.d is shipped in the deployed root via mkosi.extra/ and
# explicitly copied into the custom initrd.
grep -qE '^ExtraTrees=\.\./\.\./mkosi\.extra/usr/lib/repart\.d:/usr/lib/repart\.d$' \
        mkosi.images/initrd/mkosi.conf \
    || fail "initrd sub-image must copy mkosi.extra/usr/lib/repart.d into /usr/lib/repart.d so initrd repart has the full layout"
INITRD_REPART_OLD="mkosi.images/initrd/mkosi.extra/usr/lib/repart.d"
! [ -e "$INITRD_REPART_OLD" ] \
    || fail "$INITRD_REPART_OLD must not exist — the initrd gets repart definitions from mkosi.extra/usr/lib/repart.d via ExtraTrees"

# Both the deployed root AND the initrd must carry the
# SuccessExitStatus=1 drop-in for systemd-repart.service. After the
# first boot completes (initrd repart creates + grows data-luks to fill
# the disk, formats LUKS2+key-file+btrfs), every subsequent boot runs
# systemd-repart.service against a fully-packed disk; it exits 1 with
# "Can't fit requested partitions into available free space (0B),
# refusing." Drop-ins only apply in the filesystem they ship in, so the
# initrd needs its own copy. Drop-in suppresses the cosmetic failure.
for path in \
        mkosi.extra/usr/lib/systemd/system/systemd-repart.service.d/10-myosi.conf \
        mkosi.images/initrd/mkosi.extra/usr/lib/systemd/system/systemd-repart.service.d/10-myosi.conf; do
    [ -f "$path" ] \
        || fail "$path missing — systemd-repart.service must whitelist exit 1 (no free space) in BOTH the deployed root and the initrd"
    grep -q '^SuccessExitStatus=1$' "$path" \
        || fail "$path must set SuccessExitStatus=1"
done

# justfile build modes: dev (incremental) + full (clean rebuild). No
# --profile= flag — mkosi.conf owns the fleet profile baseline.
grep -qE 'mkosi -fi build$' justfile \
    || fail "justfile must support 'just build' / 'just build dev' (mkosi -fi build, incremental)"
grep -qE 'mkosi -ff build$' justfile \
    || fail "justfile must support 'just build full' (mkosi -ff build, clean rebuild)"
! grep -qE -- '--profile=' justfile \
    || fail "justfile must not pass --profile= because mkosi.conf owns the fleet profile baseline"

# systemd-credentials first-boot infrastructure: the credstore
# directories must ship in the image so operators can drop creds
# without touching mkosi config. systemd-firstboot.service consumes
# them on first boot (ConditionFirstBoot=yes). The .cred example
# documents which credential names are consumed by which units.
[ -d mkosi.extra/etc/credstore ] \
    || fail "mkosi.extra/etc/credstore/ must ship in the image (operator credential staging)"
[ -d mkosi.extra/etc/credstore.encrypted ] \
    || fail "mkosi.extra/etc/credstore.encrypted/ must ship in the image (TPM2/host-key sealed creds)"
[ -f mkosi.extra/usr/share/myosi/credentials/README.cred.example ] \
    || fail "credentials reference doc must ship at /usr/share/myosi/credentials/README.cred.example"
# 35-credentials.just was retired — operators use systemd-creds directly
# (encrypt / decrypt / list). The credstore + reference doc stay in
# place; only the recipe wrappers are gone.
! [ -f mkosi.extra/usr/share/myosi/just/35-credentials.just ] \
    || fail "35-credentials.just was retired — operators run systemd-creds directly, see README §3"

# Portable services (systemd-portabled / portablectl) are the myosi-
# blessed mechanism for self-contained service images with their own
# /etc namespace. On Fedora 44, portablectl ships in systemd-container
# (verified: rpm -qf /usr/bin/portablectl) and systemd-portabled ships
# in systemd-udev — both already part of the base via systemd-container
# being explicitly listed. No separate systemd-portable package exists
# on Fedora 44.
grep -q '^\s*systemd-container\s*$' mkosi.conf.d/10-packages-base.conf \
    || fail "10-packages-base.conf must include systemd-container (provides portablectl + nspawn on Fedora 44)"
! grep -qE '^\s*systemd-portable\s*$' mkosi.conf.d/10-packages-base.conf \
    || fail "10-packages-base.conf must NOT list systemd-portable — that RPM does not exist on Fedora 44; portablectl ships in systemd-container"
# 45-portables.just was retired — operators run portablectl directly
# (attach / detach / list / inspect). portablectl ships in
# systemd-container which stays in base.
! [ -f mkosi.extra/usr/share/myosi/just/45-portables.just ] \
    || fail "45-portables.just was retired — operators run portablectl directly, see README §3"

# No-confext design constraint: stock myosi prefers sysexts + portable
# services and ships no confext images, so systemd-confext.service is
# dormant on boot. /etc is a real persistent btrfs subvol (no overlay
# upperdir to layer a confext over). systemd-confext.service is NOT
# masked — operators who later want confext can `systemctl enable
# --now systemd-confext.service` without fighting a hard mask.
! grep -qE 'ln -sfn? /dev/null "\$BUILDROOT/etc/systemd/system/systemd-confext\.service"' mkosi.postinst \
    || fail "mkosi.postinst must NOT mask systemd-confext.service — confext is dormant by default but reachable for operators who want to opt in"
# 50-myosi.preset must NOT enable systemd-confext.
! grep -qE '^enable systemd-confext' mkosi.extra/usr/lib/systemd/system-preset/50-myosi.preset \
    || fail "50-myosi.preset must not enable systemd-confext.service"
# install.just must invoke that exact path, not a stale install/install.sh.
grep -q '/usr/libexec/myosi/install' mkosi.extra/usr/share/myosi/just/40-install.just \
    || fail "40-install.just must invoke /usr/libexec/myosi/install"
# Install script must expose --reset-identity and the release-fetch flow.
grep -q -- '--reset-identity' mkosi.extra/usr/libexec/myosi/install \
    || fail "install script must support --reset-identity"
# Release fetch must go through lib.sh helpers (gh-then-curl with token),
# NOT a raw curl against the public download URL — that path is dead for
# a private repo.
grep -q 'download_release_asset' mkosi.extra/usr/libexec/myosi/install \
    || fail "install script must use download_release_asset (gh→curl+token, private-repo aware)"
grep -q 'list_release_assets' mkosi.extra/usr/libexec/myosi/install \
    || fail "install script must use list_release_assets to handle split-part releases"
# lib.sh must define both helpers and the token plumbing.
for fn in list_release_assets download_release_asset _gh_token _gh_auth_ok \
          resolve_version sysupdate_env resolve_boot_disk; do
    grep -q "^${fn}()" mkosi.extra/usr/libexec/myosi/lib.sh \
        || fail "lib.sh must define ${fn}()"
done

# Storage / pool / LUKS / portable / credential wrappers were removed
# from the myosi recipe set on 2026.06.09 — operators run the upstream
# tools (cryptsetup, systemd-cryptenroll, btrfs, portablectl,
# systemd-creds) directly per the README §3 runbook. Make sure they
# don't sneak back in.
for stale in 20-storage 25-data-luks 30-security 35-credentials 45-portables; do
    ! [ -f "mkosi.extra/usr/share/myosi/just/${stale}.just" ] \
        || fail "${stale}.just was retired — operator runs upstream tools directly, see README §3"
done

# virt-setup must not reference the removed /usr/libexec/myosi/extension-enable.
! grep -q '/usr/libexec/myosi/extension-enable' mkosi.profiles/virt/mkosi.extra/usr/libexec/myosi/virt-setup \
    || fail "virt-setup must point operators at 'myosi extension-enable' (the libexec path is gone)"

# Dynamic dispatch wrapper: myosi must build its justfile from a directory
# scan, so sysexts can drop NN-<name>.just modules without the base
# image knowing about them in advance.
grep -q 'find "\$JUST_DIR"' mkosi.extra/usr/local/bin/myosi \
    || fail "/usr/local/bin/myosi must build its justfile from a directory scan"
# The static aggregator is gone — wrapper builds dispatch dynamically.
# Internal recipe-to-recipe calls must reference target modules by path,
# not the dead /usr/share/justfile.
! grep -rn 'just -f /usr/share/justfile' \
        mkosi.extra/usr/share/myosi/just/ \
    || fail "recipe-to-recipe calls must use the module path (just -f /usr/share/myosi/just/NN-name.just), not the removed aggregator"

# Virt profile/sysext must ship its own just module so myosi virt-setup
# appears only when virt is active.
[ -f mkosi.profiles/virt/mkosi.extra/usr/share/myosi/just/50-virt.just ] \
    || fail "virt profile must ship usr/share/myosi/just/50-virt.just for profile-provided recipe discovery"
grep -q '^virt-setup ' mkosi.profiles/virt/mkosi.extra/usr/share/myosi/just/50-virt.just \
    || fail "50-virt.just must define a virt-setup recipe"

# Static checks:
#   - apply / vacuum / extension-disable / extension-list must invoke
#     sysupdate through "$SYSUPDATE" so the MYOSI_SYSUPDATE_BIN env
#     override lets operators (and this CI) swap the backend out
#     (e.g. swap in `updatectl` when selinux-policy supports it).
#   - The `[ -x "$SYSUPDATE" ]` shape would test for a file literally
#     named `sysupdate` in cwd — wrong for a PATH-resolved command.
#     Recipes must use `command -v` instead.
APPLY="mkosi.extra/usr/share/myosi/just/00-update.just"
VACUUM_EXT="mkosi.extra/usr/share/myosi/just/10-extensions.just"
for f in "$APPLY" "$VACUUM_EXT"; do
    if grep -qE '\[\s*-x\s+"\$SYSUPDATE"\s*\]' "$f"; then
        fail "$f must use \`command -v \"\$SYSUPDATE\"\` (PATH lookup), not \`[ -x \"\$SYSUPDATE\" ]\` (cwd lookup)"
    fi
done

# `apply` must thread version via {{version}} interpolation (just shebang
# bodies do NOT inherit positional args).
grep -qE '\{\{version\}\}' "$APPLY" || \
    fail "00-update.just apply must thread version via {{version}} interpolation"
! grep -qE 'update_target host "\$@"' "$APPLY" || \
    fail "00-update.just apply must not use \$@ (just shebang has no positional args)"

# End-to-end: stub sysupdate, drive `myosi apply VER` through the just
# recipe, assert the stub got called with the right component + version.
if command -v just >/dev/null; then
    TMPDIR="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR"' EXIT

    STUB="$TMPDIR/sysupdate"
    LOG="$TMPDIR/su.log"
    cat > "$STUB" <<'STUBEOF'
#!/usr/bin/env bash
component=host
verb=
version=
for a in "$@"; do
    case "$a" in
        --component=*) component="${a#--component=}";;
        update|vacuum|list|check-new|features|pending|reboot|components)
            verb="$a";;
        *) [ -z "$verb" ] || version="$a";;
    esac
done
target="$component"
[ "$component" = host ] || target="component:$component"
if [ -n "$verb" ]; then
    if [ -n "$version" ]; then
        printf '%s %s@%s\n' "$verb" "$target" "$version" >> "${MYOSI_TEST_SYSUPDATE_LOG}"
    else
        printf '%s %s\n' "$verb" "$target" >> "${MYOSI_TEST_SYSUPDATE_LOG}"
    fi
fi
STUBEOF
    chmod +x "$STUB"

    SU_DIR="$TMPDIR/su.d"
    EXT_DIR="$TMPDIR/ext.d"
    MACHINES_DIR="$TMPDIR/machines.d"
    CACHE="$TMPDIR/cache"
    mkdir -p "$SU_DIR" "$EXT_DIR" "$MACHINES_DIR" "$CACHE"
    touch "$SU_DIR/10-root.transfer" "$EXT_DIR/30-desktop.transfer"
    VERSION="2026.06.04.01"
    # root + verity cache files now ship with arch in the name + the
    # verity-roothash-derived PartitionUUID. The preflight glob in the
    # apply recipe matches myosi_VER_ARCH_*.{root,verity}.raw.zst.
    # Match the host's arch so the synthesized fixture exercises the
    # same code path as a real cache.
    ARCH=$(uname -m | sed -e 's/^x86_64$/x86-64/' -e 's/^aarch64$/arm64/')
    : > "$CACHE/myosi_${VERSION}_${ARCH}_00000000-0000-0000-0000-000000000001.root.raw.zst"
    : > "$CACHE/myosi_${VERSION}_${ARCH}_00000000-0000-0000-0000-000000000002.verity.raw.zst"
    for asset in \
        "myosi_${VERSION}_${ARCH}.verity-sig.raw.zst" \
        "myosi_${VERSION}_${ARCH}.efi"; do
        : > "$CACHE/$asset"
    done

    # Stub lib.sh so require_root passes from non-root CI runners.
    # Includes a sysupdate_env that honours the test's env overrides so
    # the recipe reaches the stub binary instead of the real sysupdate.
    STUB_LIB="$TMPDIR/lib.sh"
    cat > "$STUB_LIB" <<'LIBEOF'
require_root() { :; }
require_gh() { :; }
refresh_sysext() { :; }
resolve_latest_release() { echo "2026.06.04.01"; }
resolve_version() {
    local v="${1:-}"
    if [ -n "$v" ] && [ "$v" != latest ]; then printf '%s\n' "$v"; return; fi
    resolve_latest_release
}
sysupdate_env() {
    SYSUPDATE="${MYOSI_SYSUPDATE_BIN:-sysupdate}"
    SU_DIR="${MYOSI_SYSUPDATE_DIR:-/usr/lib/sysupdate.d}"
    EXT_DIR="${MYOSI_SYSUPDATE_EXTENSIONS_DIR:-/usr/lib/sysupdate.extensions.d}"
    MACHINES_DIR="${MYOSI_SYSUPDATE_MACHINES_DIR:-/usr/lib/sysupdate.machines.d}"
    CACHE="${MYOSI_RELEASE_CACHE:-/var/lib/sysupdate}"
}
LIBEOF
    LIBEXEC_OVERRIDE="$TMPDIR/libexec"
    mkdir -p "$LIBEXEC_OVERRIDE"
    install -m 0644 "$STUB_LIB" "$LIBEXEC_OVERRIDE/lib.sh"

    APPLY_RECIPE="$TMPDIR/apply.just"
    APPLY_OUT="$TMPDIR/apply.out"
    # Re-write the . /usr/libexec/myosi/lib.sh line to our stub path.
    sed "s|/usr/libexec/myosi/lib.sh|$LIBEXEC_OVERRIDE/lib.sh|g" \
        "$APPLY" > "$APPLY_RECIPE"

    : > "$LOG"
    MYOSI_SYSUPDATE_BIN="$STUB" \
    MYOSI_SYSUPDATE_DIR="$SU_DIR" \
    MYOSI_SYSUPDATE_EXTENSIONS_DIR="$EXT_DIR" \
    MYOSI_SYSUPDATE_MACHINES_DIR="$MACHINES_DIR" \
    MYOSI_RELEASE_CACHE="$CACHE" \
    MYOSI_TEST_SYSUPDATE_LOG="$LOG" \
        just -f "$APPLY_RECIPE" apply "$VERSION" >"$APPLY_OUT" 2>&1 || \
        fail "apply recipe failed: $(cat "$APPLY_OUT")"

    grep -q "update host@${VERSION}" "$LOG" || \
        fail "apply did not invoke sysupdate for host@$VERSION (log=$(cat $LOG))"
    grep -q "update component:extensions@${VERSION}" "$LOG" || \
        fail "apply did not invoke sysupdate for component:extensions@$VERSION (log=$(cat $LOG))"

    rm -rf "$TMPDIR"
    trap - EXIT
fi

echo "ok - update model + myosi wrapper"
