#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

HELPER="mkosi.shared/sysext-build.sh"

grep -q '^sysext_enable_system_units()' "$HELPER" || fail "missing sysext_enable_system_units helper"
grep -q '^sysext_enable_user_units()' "$HELPER" || fail "missing sysext_enable_user_units helper"
grep -q '^sysext_uphold_system_units()' "$HELPER" || fail "missing sysext_uphold_system_units helper"
grep -q '^sysext_uphold_user_units()' "$HELPER" || fail "missing sysext_uphold_user_units helper"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
BUILDROOT="$TMPDIR/root"
mkdir -p "$BUILDROOT/usr/lib/systemd/system" "$BUILDROOT/usr/lib/systemd/user"
touch "$BUILDROOT/usr/lib/systemd/system/example.service"
touch "$BUILDROOT/usr/lib/systemd/system/example@.service"
touch "$BUILDROOT/usr/lib/systemd/user/example.socket"
# shellcheck source=/dev/null
. "$HELPER"

# Exercise per-sysext drop-in naming. Multiple sysexts overlay-merging
# onto /usr would collide on a shared filename — the helper must use
# ${IMAGE_ID} (set per-sub-image by mkosi) so each sysext writes a
# distinct drop-in that systemd then merges at boot.
IMAGE_ID=example
export IMAGE_ID
sysext_uphold_system_units multi-user.target example.service example@alpha.service
sysext_uphold_user_units sockets.target example.socket
grep -q '^Upholds=example.service example@alpha.service$' \
    "$BUILDROOT/usr/lib/systemd/system/multi-user.target.d/50-myosi-example.conf" || \
    fail "system target drop-in must uphold services under per-sysext name"
grep -q '^Upholds=example.socket$' \
    "$BUILDROOT/usr/lib/systemd/user/sockets.target.d/50-myosi-example.conf" || \
    fail "user target drop-in must uphold services under per-sysext name"
[ ! -e "$BUILDROOT/usr/lib/systemd/system/multi-user.target.d/50-myosi-sysext.conf" ] || \
    fail "helper must not fall back to the collision-prone 50-myosi-sysext.conf when IMAGE_ID is set"
unset IMAGE_ID
[ ! -e "$BUILDROOT/usr/lib/systemd/system/multi-user.target.wants/example.service" ] || \
    fail "system services must not be enabled through sysext .wants links"
[ ! -e "$BUILDROOT/usr/lib/systemd/user/sockets.target.wants/example.socket" ] || \
    fail "user services must not be enabled through sysext .wants links"

SYMLINK_BUILDROOT="$TMPDIR/symlink-root"
BUILDROOT="$SYMLINK_BUILDROOT"
mkdir -p "$BUILDROOT/usr/lib/systemd/system" "$BUILDROOT/usr/lib/systemd/user"
touch "$BUILDROOT/usr/lib/systemd/system/example.service"
touch "$BUILDROOT/usr/lib/systemd/system/example@.service"
touch "$BUILDROOT/usr/lib/systemd/user/example.socket"
sysext_enable_system_units multi-user.target example.service example@alpha.service
sysext_enable_user_units sockets.target example.socket
[ "$(readlink "$BUILDROOT/usr/lib/systemd/system/multi-user.target.wants/example.service")" = "../example.service" ] || \
    fail "system service symlink target is wrong"
[ "$(readlink "$BUILDROOT/usr/lib/systemd/system/multi-user.target.wants/example@alpha.service")" = "../example@.service" ] || \
    fail "templated system service symlink target is wrong"
[ "$(readlink "$BUILDROOT/usr/lib/systemd/user/sockets.target.wants/example.socket")" = "../example.socket" ] || \
    fail "user socket symlink target is wrong"
[ ! -e "$BUILDROOT/usr/lib/systemd/system/multi-user.target.d/50-myosi-sysext.conf" ] || \
    fail "symlink helper must not create uphold drop-ins"

for postinst in \
    mkosi.images/containers/mkosi.postinst \
    mkosi.images/desktop/mkosi.postinst \
    mkosi.images/virt/mkosi.postinst; do
    ! awk '!/^[[:space:]]*#/ && /systemctl enable/ { found=1 } END { exit found ? 0 : 1 }' "$postinst" || \
        fail "$postinst must not use systemctl enable inside sysext buildroot"
    grep -q 'sysext_uphold_' "$postinst" || fail "$postinst must use shared sysext uphold helpers"
done

[ -f mkosi.images/desktop/mkosi.extra/usr/lib/systemd/system/flatpak-setup-flathub.service ] || \
    fail "desktop must ship flatpak-setup-flathub.service"
grep -q 'sysext_uphold_system_units multi-user.target power-profiles-daemon.service flatpak-setup-flathub.service' \
    mkosi.images/desktop/mkosi.postinst || fail "desktop must uphold boot services under /usr"

[ -f mkosi.sandbox/etc/yum.repos.d/nvidia-container-toolkit.repo ] || \
    fail "nvidia container toolkit repo must live under mkosi.sandbox"
grep -q 'nvidia-container-toolkit' mkosi.shared/nvidia-build.sh || fail "nvidia sysext must install nvidia-container-toolkit"
grep -qE '^[[:space:]]*stage_sandbox_repos[[:space:]]*$' mkosi.shared/nvidia-build.sh || fail "nvidia sysext must stage mkosi.sandbox repos through shared helper"
grep -q '^stage_sandbox_repos()' mkosi.shared/sysext-build.sh || fail "sysext-build.sh must define stage_sandbox_repos helper"
grep -qE '^[[:space:]]*stage_sandbox_repos[[:space:]]*$' mkosi.images/desktop/mkosi.postinst || fail "desktop sysext must stage mkosi.sandbox repos through shared helper"

SANDBOX_SRCDIR="$TMPDIR/sandbox-src"
SANDBOX_BUILDROOT="$TMPDIR/sandbox-root"
mkdir -p "$SANDBOX_BUILDROOT"
BUILDROOT="$SANDBOX_BUILDROOT" SRCDIR="$SANDBOX_SRCDIR" stage_sandbox_repos 2>/dev/null && \
    fail "stage_sandbox_repos must fail when mkosi.sandbox repos are missing"
mkdir -p "$SANDBOX_SRCDIR/mkosi.sandbox/etc/yum.repos.d"
BUILDROOT="$SANDBOX_BUILDROOT" SRCDIR="$SANDBOX_SRCDIR" stage_sandbox_repos 2>/dev/null && \
    fail "stage_sandbox_repos must fail when mkosi.sandbox has no repo files"
touch "$SANDBOX_SRCDIR/mkosi.sandbox/etc/yum.repos.d/example.repo"
BUILDROOT="$SANDBOX_BUILDROOT" SRCDIR="$SANDBOX_SRCDIR" stage_sandbox_repos
[ -f "$SANDBOX_BUILDROOT/etc/yum.repos.d/example.repo" ] || \
    fail "stage_sandbox_repos must copy repo files into the buildroot"
grep -q 'sysext_uphold_system_units multi-user.target nvidia-cdi-refresh.service' \
    mkosi.shared/nvidia-build.sh || fail "nvidia sysext must uphold nvidia-cdi-refresh.service under /usr"
grep -q 'sysext_uphold_system_units multi-user.target nvidia-cdi-refresh.path' \
    mkosi.shared/nvidia-build.sh || fail "nvidia sysext must uphold nvidia-cdi-refresh.path under /usr"

# Sysexts that ship systemd units must request a post-merge manager
# reload via the EXTENSION_RELOAD_MANAGER=1 extra passed to
# sysext_write_extension_release. We validate the helper invocation
# rather than a static placeholder file: each postinst (or shared
# build script for nvidia/nvidia-580xx) writes the versioned
# extension-release directly in one shot, so there is no static
# extension-release.<name> under mkosi.extra anymore.
for caller in \
    mkosi.images/containers/mkosi.postinst \
    mkosi.images/desktop/mkosi.postinst \
    mkosi.images/virt/mkosi.postinst \
    mkosi.shared/nvidia-build.sh \
    mkosi.shared/zfs-build.sh; do
    # Collapse `\<newline>` line continuations so a multi-line
    # sysext_write_extension_release invocation flattens to one
    # grep-friendly line before the match. nvidia/zfs build scripts
    # split the call across three lines for readability.
    sed -e ':a' -e '/\\$/N' -e 's/\\\n[[:space:]]*/ /g' -e 'ta' "$caller" | \
        grep -qE 'sysext_write_extension_release.*EXTENSION_RELOAD_MANAGER=1' || \
        fail "$caller must request a manager reload via EXTENSION_RELOAD_MANAGER=1"
done

grep -q 'NVIDIA_BUILD_OPTIONAL=1' mkosi.images/nvidia-580xx/mkosi.postinst || \
    fail "nvidia-580xx must set NVIDIA_BUILD_OPTIONAL=1 for legacy branch"
! grep -q 'NVIDIA_BUILD_OPTIONAL' mkosi.images/nvidia/mkosi.postinst || \
    fail "nvidia current branch must not be optional"

# Shared kmod helpers must be sourced (via mkosi.shared/kmod-build.sh)
# and invoked by every kmod sysext. Each helper is described in
# kmod-build.sh; the assertions below pin the calling pattern so this
# regression cannot re-appear:
#   - kmod_sign_modules  → module signing under module.sig_enforce=1
#   - kmod_depmod_after_strip → index survives the post-build dnf remove
#   - kmod_mark_indices_unique → mkosi v26 de-dup keeps index files
#   - kmod_indexed       → build refuses to ship an incomplete index
KMOD_HELPER="mkosi.shared/kmod-build.sh"
for helper in kmod_sign_modules kmod_depmod_after_strip \
              kmod_mark_indices_unique kmod_indexed kmod_ship_empty_stub; do
    grep -q "^${helper}()" "$KMOD_HELPER" || \
        fail "kmod-build.sh must define ${helper}"
done

for kmod_script in \
    mkosi.shared/nvidia-build.sh \
    mkosi.shared/zfs-build.sh; do
    grep -q 'kmod_sign_modules ' "$kmod_script" || \
        fail "$kmod_script must call kmod_sign_modules"
    grep -q 'kmod_depmod_after_strip' "$kmod_script" || \
        fail "$kmod_script must call kmod_depmod_after_strip"
    grep -q 'kmod_mark_indices_unique ' "$kmod_script" || \
        fail "$kmod_script must call kmod_mark_indices_unique"
    grep -q 'kmod_indexed ' "$kmod_script" || \
        fail "$kmod_script must call kmod_indexed before sealing"
done

echo "ok - sysext systemd enablement"
