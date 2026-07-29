#!/usr/bin/env bash
set -euo pipefail

# Generates signing material in keys/: boot.key/.crt (signs sd-boot +
# UKI, enrolled PK/KEK/db), image.key/.crt (signs dm-verity root hash +
# sysexts, enrolled db), and OVMF_VARS-enrolled.fd (SecureBoot varstore
# for qemu). All regenerate together; private material is git-ignored,
# CI writes release material to the same paths.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_DIR="$(cd "${SCRIPT_DIR}/../keys" && pwd)"

cd "${KEYS_DIR}"

if [[ -f boot.key && -f image.key ]]; then
    echo "Signing keys already exist in ${KEYS_DIR}." >&2
    echo "Reusing them for OVMF varstore enrollment." >&2
elif [[ -f boot.key || -f image.key ]]; then
    echo "ERROR: inconsistent state — only one of boot.key/image.key exists in ${KEYS_DIR}." >&2
    echo "Delete both (and OVMF_VARS-enrolled.fd) to regenerate from scratch." >&2
    exit 1
else
    echo "Generating boot.key (RSA-4096, SHA-384, 5y)..."
    openssl req -newkey rsa:4096 -keyform PEM -keyout boot.key \
        -x509 -sha384 -days 1825 -nodes \
        -subj "/CN=myosi Boot/O=myosi/" \
        -addext "extendedKeyUsage=1.3.6.1.5.5.7.3.3,1.3.6.1.4.1.311.10.3.6" \
        -out boot.crt

    echo "Generating image.key (RSA-4096, SHA-384, 5y)..."
    # Not Ed25519: the dm-verity signature path wraps the root hash in
    # PKCS7/CMS, and OpenSSL 3.x refuses to PKCS7-sign with EdDSA keys.
    openssl req -newkey rsa:4096 -keyform PEM -keyout image.key \
        -x509 -sha384 -days 1825 -nodes \
        -subj "/CN=myosi Image/O=myosi/" \
        -out image.crt

    chmod 600 boot.key image.key
    chmod 644 boot.crt image.crt
fi

# OVMF varstore: boot.crt (PK/KEK/db) + image.crt (db). The kernel
# loads .platform from firmware db, so image.crt must be enrolled for
# dm-verity roothash signature validation to pass.
if [[ -f OVMF_VARS-enrolled.fd ]]; then
    echo "OVMF_VARS-enrolled.fd already present; delete to regenerate." >&2
else
    OVMF_BASE=""
    # OVMF_CODE_4M.secboot expects a 4M varstore; a 2M OVMF_VARS.fd is
    # silently rejected → "No bootable option". Prefer 4M variants,
    # converting qcow2 to raw if that's all that ships.
    for p in \
        /usr/share/edk2/ovmf/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/edk2-ovmf/OVMF_VARS_4M.fd; do
        if [[ -f "$p" ]]; then
            OVMF_BASE="$p"
            break
        fi
    done
    if [[ -z "$OVMF_BASE" ]] && command -v qemu-img >/dev/null; then
        for q in \
            /usr/share/edk2/ovmf/OVMF_VARS_4M.qcow2 \
            /usr/share/OVMF/OVMF_VARS_4M.qcow2 \
            /usr/share/edk2-ovmf/OVMF_VARS_4M.qcow2; do
            if [[ -f "$q" ]]; then
                qemu-img convert -O raw "$q" /tmp/OVMF_VARS_4M.fd
                OVMF_BASE=/tmp/OVMF_VARS_4M.fd
                break
            fi
        done
    fi
    # Last-resort 2M fallback for distros without 4M variants.
    if [[ -z "$OVMF_BASE" ]]; then
        for p in \
            /usr/share/edk2/ovmf/OVMF_VARS.fd \
            /usr/share/OVMF/OVMF_VARS.fd \
            /usr/share/edk2-ovmf/OVMF_VARS.fd; do
            if [[ -f "$p" ]]; then
                OVMF_BASE="$p"
                break
            fi
        done
    fi

    if [[ -z "$OVMF_BASE" ]]; then
        echo "WARNING: no OVMF_VARS.fd template found." >&2
        echo "Install edk2-ovmf (dnf install edk2-ovmf) and rerun this script." >&2
        echo "Skipping OVMF varstore enrollment." >&2
    elif ! /usr/bin/python3 -c "import virt.firmware.varstore.edk2" >/dev/null 2>&1; then
        echo "WARNING: virt-firmware library not available to /usr/bin/python3." >&2
        echo "Install virt-firmware (dnf install python3-virt-firmware) and rerun." >&2
        echo "Skipping OVMF varstore enrollment." >&2
    else
        echo "Generating OVMF_VARS-enrolled.fd from ${OVMF_BASE}..."
        # The virt-fw-vars CLI cannot combine file-based PK/KEK/db with
        # Microsoft key enrollment in one pass; drive the library
        # directly so our certs AND the Microsoft CA/KEK land in the
        # varstore (needed for Fedora's signed shim to validate).
        /usr/bin/python3 - "${OVMF_BASE}" OVMF_VARS-enrolled.fd boot.crt image.crt <<'PY'
import sys, uuid
from virt.firmware.varstore import edk2

base, out, boot_crt, image_crt = sys.argv[1:5]
owner = str(uuid.uuid4())
store = edk2.Edk2VarStore(base)
vl = store.get_varlist()

vl.add_cert('PK',  owner, boot_crt,  True)
vl.add_cert('KEK', owner, boot_crt)
vl.add_cert('db',  owner, boot_crt)
vl.add_cert('db',  owner, image_crt)
vl.add_cert('MokList', owner, boot_crt)
vl.add_microsoft_kek_keys('all')
vl.add_microsoft_keys('all')
vl.enable_secureboot()

store.write_varstore(out, vl)
PY
        chmod 644 OVMF_VARS-enrolled.fd
    fi
fi

echo
echo "Signing artifacts in ${KEYS_DIR}:"
ls -l "${KEYS_DIR}"
