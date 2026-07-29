#!/usr/bin/env bash
set -euo pipefail

# Stage the LUKS bootstrap key at keys/data.key. From there:
#   - mkosi.postinst installs it into the main image at
#     /usr/share/myosi/keys/data.key and onto the ESP at
#     /efi/keys/data.key.
#   - mkosi.images/initrd/mkosi.conf ExtraTrees= pulls
#     it into the initrd cpio at /usr/share/myosi/keys/data.key.
# Same lifecycle as keys/{boot,image}.{key,crt}: persistent across
# builds, sourced from a GitHub Actions secret in CI, regenerated only
# if neither secret nor persistent copy exists.
#
# Source resolution:
#
#   1. If $MYOSI_DATA_KEY is set in the environment, base64-decode it.
#      This is the CI path — store the raw 32 bytes base64-encoded as
#      a GitHub Actions secret named MYOSI_DATA_KEY.
#   2. Otherwise, if keys/data.key exists, reuse it. Local-dev path.
#   3. Otherwise, generate a fresh random 32-byte key. First local
#      build only.
#
# Why stable across releases (not random per build): every UKI ships
# with the bootstrap key inside its .initrd cpio. If the key value
# changed per build, sysupdate would replace UKI_v1 with UKI_v2,
# leaving LUKS slot 0 bound to key_v1 while the new initrd's
# /usr/share/myosi/keys/data.key now contains key_v2. cryptsetup
# would fail to unlock, fall through to TPM2 / passphrase, and the
# operator would be locked out of their data — unless they had run
# `myosi data-finalize` (enrolled real auth + wiped slot 0) before
# updating. Stable key removes that footgun.
#
# Leak severity: if the key value escapes (CI artifact published,
# secret rotated incorrectly, repo private key committed), every
# install of every version that hasn't yet wiped slot 0 is
# compromised. Treat MYOSI_DATA_KEY with the same care as the signing
# keys (MYOSI_BOOT_KEY, MYOSI_IMAGE_KEY).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KEY_DST="${ROOT}/keys/data.key"

mkdir -p "$(dirname "$KEY_DST")"
chmod 700 "$(dirname "$KEY_DST")" 2>/dev/null || true

source_mode=""

if [ -n "${MYOSI_DATA_KEY:-}" ]; then
    source_mode="env (MYOSI_DATA_KEY)"
    echo "$MYOSI_DATA_KEY" | base64 -d > "$KEY_DST"
elif [ -s "$KEY_DST" ]; then
    source_mode="cached"
    # leave it alone
else
    source_mode="generated"
    openssl rand 32 > "$KEY_DST"
fi

chmod 0600 "$KEY_DST"

bytes=$(stat -c %s "$KEY_DST")
if [ "$bytes" -ne 32 ]; then
    echo "ERROR: $KEY_DST is $bytes bytes, expected 32." >&2
    echo "If MYOSI_DATA_KEY was set, it likely wasn't base64 of 32 raw bytes." >&2
    echo "Regenerate with: openssl rand 32 | base64 -w0" >&2
    exit 1
fi

echo "Bootstrap LUKS key staged at $KEY_DST"
echo "  source: $source_mode"
