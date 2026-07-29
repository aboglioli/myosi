#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

# lib.sh is the shared library sourced by all operator code
LIB="mkosi.extra/usr/libexec/myosi/lib.sh"
[ -f "$LIB" ] || fail "lib.sh missing"
bash -n "$LIB" 2>/dev/null || fail "lib.sh has syntax errors"

for fn in require_root require_gh validate_name resolve_latest_release \
    feature_enable feature_disable refresh_sysext; do
    grep -q "^${fn}()" "$LIB" || fail "lib.sh missing function: $fn"
done

# myosi wrapper exists and is executable
WRAPPER="mkosi.extra/usr/local/bin/myosi"
[ -x "$WRAPPER" ] || fail "myosi wrapper must exist and be executable"
bash -n "$WRAPPER" 2>/dev/null || fail "myosi wrapper has syntax errors"

# Just modules exist in the discovery directory. There is no static
# aggregator anymore — the myosi wrapper scans this directory at every
# invocation and emits a transient justfile in /run.
JUST_DIR="mkosi.extra/usr/share/myosi/just"
[ -d "$JUST_DIR" ] || fail "$JUST_DIR missing — wrapper has nothing to import"
for mod in update extensions install; do
    ls "$JUST_DIR"/[0-9][0-9]-"${mod}".just >/dev/null 2>&1 \
        || fail "missing base module: NN-${mod}.just"
done

# Verify extension recipes exist
grep -q 'extension-enable' mkosi.extra/usr/share/myosi/just/10-extensions.just || \
    fail "extensions module must define extension-enable"
grep -q 'extension-disable' mkosi.extra/usr/share/myosi/just/10-extensions.just || \
    fail "extensions module must define extension-disable"
grep -q '. /usr/libexec/myosi/lib.sh' mkosi.extra/usr/share/myosi/just/10-extensions.just || \
    fail "extension recipes must source lib.sh"

# Verify nvidia builds still call sysext_finalize (not manual two-step)
grep -q 'sysext_finalize' mkosi.shared/nvidia-build.sh || \
    fail "nvidia-build.sh must call sysext_finalize"
grep -q 'sysext_finalize' mkosi.shared/zfs-build.sh || \
    fail "zfs-build.sh must call sysext_finalize"

# Verify nvidia-580xx is optional, current is required
grep -q 'NVIDIA_BUILD_OPTIONAL=1' mkosi.images/nvidia-580xx/mkosi.postinst || \
    fail "nvidia-580xx must set NVIDIA_BUILD_OPTIONAL=1"
! grep -q 'NVIDIA_BUILD_OPTIONAL' mkosi.images/nvidia/mkosi.postinst || \
    fail "nvidia current branch must not be optional"

# Verify sysext postinsts use shared helpers
for postinst in \
    mkosi.images/containers/mkosi.postinst \
    mkosi.images/desktop/mkosi.postinst \
    mkosi.images/virt/mkosi.postinst; do
    ! awk '!/^[[:space:]]*#/ && /systemctl enable/ { found=1 } END { exit found ? 0 : 1 }' "$postinst" || \
        fail "$postinst must not use systemctl enable inside sysext buildroot"
    grep -q 'sysext_uphold_' "$postinst" || fail "$postinst must use shared sysext uphold helpers"
done

echo "ok - extension lifecycle + myosi wrapper"
