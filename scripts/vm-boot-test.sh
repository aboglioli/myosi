#!/usr/bin/env bash
# Boot a myosi image on an empty disk and assert the result, headless and
# unattended. Same script for CI and for a laptop.
#
# The control channel is SSH over TCP, forwarded out of QEMU's user-mode
# network, not the console. tmpfiles.d/myosi.conf consumes the
# ssh.authorized_keys.root system credential, so QEMU can hand the VM a
# throwaway public key at launch via SMBIOS type 11 and get a real shell
# with no changes to the image and no console scraping.
#
# This used to run over AF_VSOCK, which was neater — no port to allocate —
# but it broke twice for reasons that had nothing to do with the image:
# /dev/vhost-vsock is root-only on a stock runner, and selinux-policy 44.7
# denies AF_VSOCK socket activation outright, so sshd accepted the
# connection and then never wrote its banner. TCP reaches the same sshd
# over the path a real host is reached by, and depends on nothing but the
# NIC the VM already had.
#
# Every run starts from a fresh qcow2 built from the image, which is the
# only way to test first-boot behaviour: repart builds the pool, tmpfiles
# runs once, and nothing survives from a previous version.
#
# Usage:  scripts/vm-boot-test.sh <image.raw|image.raw.zst> [workdir]
# Env:    SB_CERT=keys/boot.crt   enroll it as PK/KEK/db and boot Secure Boot
#         BOOT_TIMEOUT=300        seconds to wait for SSH
#         KEEP=1                  leave the VM running for poking at

set -euo pipefail

IMAGE=${1:?usage: vm-boot-test.sh <image.raw|.raw.zst> [workdir]}
WORK=${2:-build/vm-test}
SB_CERT=${SB_CERT:-}
KEEP=${KEEP:-}
HERE=$(cd "$(dirname "$0")" && pwd)

mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
PIDFILE="$WORK/qemu.pid"
TPMDIR="$WORK/tpm"

# A free loopback port for the SSH forward. Concurrent runs on one host must
# not collide, and picking a fixed one silently hands the run to whatever
# already answers there — which is exactly how a stray host sshd once passed
# itself off as the guest.
pick_port() {
    local p
    for _ in $(seq 50); do
        p=$(( (RANDOM % 20000) + 20000 ))
        (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || { echo "$p"; return 0; }
    done
    echo "no free port in 20000-40000" >&2; return 1
}
PORT=$(pick_port)

cleanup() {
    rc=$?
    if [ -z "$KEEP" ]; then
        [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
        pkill -F "$WORK/swtpm.pid" 2>/dev/null || true
        rm -f "$WORK"/*.sock
    fi
    exit $rc
}
trap cleanup EXIT

say() { printf '\n== %s ==\n' "$1"; }

say "prepare disk"
RAW="$WORK/image.raw"
case "$IMAGE" in
    *.zst) zstd -d -f -o "$RAW" "$IMAGE" >/dev/null ;;
    *)     cp --reflink=auto "$IMAGE" "$RAW" ;;
esac
rm -f "$WORK/disk.qcow2"
qemu-img convert -f raw -O qcow2 "$RAW" "$WORK/disk.qcow2"
qemu-img resize "$WORK/disk.qcow2" 20G >/dev/null
rm -f "$RAW"
echo "  fresh 20G disk from $(basename "$IMAGE")"

say "firmware"
# Ubuntu and Fedora disagree on OVMF paths; take whichever exists.
find_fw() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return; }; done; }
if [ -n "$SB_CERT" ]; then
    CODE=$(find_fw /usr/share/OVMF/OVMF_CODE_4M.secboot.fd \
                   /usr/share/edk2/ovmf/OVMF_CODE.secboot.fd)
else
    CODE=$(find_fw /usr/share/OVMF/OVMF_CODE_4M.fd \
                   /usr/share/edk2/ovmf/OVMF_CODE.fd)
fi
if [ -n "$SB_CERT" ]; then
    # Must be the Secure Boot vars template, not the blank one. Enrolling
    # into the blank store produces a db that OVMF ignores: the firmware
    # rejects the UKI with "Access Denied -- rejected probably by Secure
    # Boot" and falls through to PXE. Verified both ways on the same image.
    # Our cert is appended to the vendor keys this template already holds.
    VARS_TMPL=$(find_fw /usr/share/OVMF/OVMF_VARS_4M.ms.fd \
                        /usr/share/edk2/ovmf/OVMF_VARS.secboot.fd)
else
    VARS_TMPL=$(find_fw /usr/share/OVMF/OVMF_VARS_4M.fd \
                        /usr/share/edk2/ovmf/OVMF_VARS.fd)
fi
[ -n "${CODE:-}" ] && [ -n "${VARS_TMPL:-}" ] || { echo "no OVMF firmware found" >&2; exit 1; }
VARS="$WORK/vars.fd"
if [ -n "$SB_CERT" ]; then
    # Enroll our own PK/KEK/db so the signed UKI verifies. Non-interactive:
    # no OVMF menu, unlike enrolling by hand.
    GUID=$(uuidgen)
    virt-fw-vars --input "$VARS_TMPL" --output "$VARS" \
        --set-pk "$GUID" "$SB_CERT" \
        --add-kek "$GUID" "$SB_CERT" \
        --add-db "$GUID" "$SB_CERT" \
        --secure-boot >/dev/null
    echo "  Secure Boot on, $(basename "$SB_CERT") enrolled as PK/KEK/db"
else
    cp "$VARS_TMPL" "$VARS"
    echo "  Secure Boot off (set SB_CERT=keys/boot.crt to enable)"
fi

say "tpm + ssh credential"
rm -rf "$TPMDIR"; mkdir -p "$TPMDIR"
swtpm socket --tpmstate dir="$TPMDIR" --ctrl type=unixio,path="$WORK/swtpm.sock" \
    --tpm2 --pid file="$WORK/swtpm.pid" -d
rm -f "$WORK/id" "$WORK/id.pub"
ssh-keygen -q -t ed25519 -N '' -f "$WORK/id" -C myosi-vm-test
# .binary + base64 sidesteps every quoting hazard in the SMBIOS string.
CRED=$(base64 -w0 < "$WORK/id.pub")
echo "  throwaway key generated, ssh on 127.0.0.1:$PORT"

say "boot"
ACCEL="-accel tcg -cpu max"; TMO=${BOOT_TIMEOUT:-900}
if [ -r /dev/kvm ]; then ACCEL="-accel kvm -cpu host"; TMO=${BOOT_TIMEOUT:-300}; fi
echo "  ${ACCEL#-accel }, timeout ${TMO}s"
# shellcheck disable=SC2086
qemu-system-x86_64 \
  -machine q35,smm=on $ACCEL -smp 4 -m 4G \
  -global driver=cfi.pflash01,property=secure,value=on \
  -global ICH9-LPC.disable_s3=1 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$CODE" \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  -drive if=virtio,format=qcow2,file="$WORK/disk.qcow2" \
  -chardev socket,id=chrtpm,path="$WORK/swtpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-crb,tpmdev=tpm0 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:22 \
  -device virtio-net-pci,netdev=n0 \
  -smbios type=11,value=io.systemd.credential.binary:ssh.authorized_keys.root=$CRED \
  -display none -serial file:"$WORK/console.log" \
  -pidfile "$PIDFILE" -daemonize

# The port is reused across runs, so a remembered host key would be a
# false mismatch every time; the VM is throwaway and so is its key.
SSH=(ssh -q -i "$WORK/id" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
     -o ConnectTimeout=5 -o LogLevel=ERROR -p "$PORT" root@127.0.0.1)

say "wait for ssh"
deadline=$(( SECONDS + TMO ))
until "${SSH[@]}" true 2>/dev/null; do
    if [ $SECONDS -ge $deadline ]; then
        echo "  VM never came up within ${TMO}s; console tail:" >&2
        tail -40 "$WORK/console.log" >&2 || true
        exit 1
    fi
    if ! { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }; then
        echo "  qemu died; console tail:" >&2; tail -40 "$WORK/console.log" >&2; exit 1
    fi
    sleep 3
done
echo "  up after $SECONDS s"

say "assertions"
rc=0
"${SSH[@]}" 'bash -s' < "$HERE/vm-test-assertions.sh" || rc=$?

say "collect logs"
"${SSH[@]}" 'journalctl -b --no-pager' > "$WORK/guest-journal.log" 2>/dev/null || true
echo "  $WORK/guest-journal.log, $WORK/console.log"

# qemu removes its own pidfile on exit, so the file being gone is itself
# the success signal — read it defensively rather than letting cat spew.
qemu_alive() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; }

if [ -z "$KEEP" ]; then
    say "shutdown"
    "${SSH[@]}" 'systemctl poweroff' 2>/dev/null || true
    for _ in $(seq 30); do qemu_alive || break; sleep 1; done
    if qemu_alive; then echo "  did not power off cleanly"; rc=${rc:-1}; else echo "  clean poweroff"; fi
fi
exit $rc
