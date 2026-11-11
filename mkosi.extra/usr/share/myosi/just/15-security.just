[group('security')]
security-check:
    #!/usr/bin/env bash
    set -uo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root

    rc=0
    pass() { printf 'ok    %s\n' "$*"; }
    warn() { printf 'WARN  %s\n' "$*" >&2; rc=1; }
    fail() { printf 'FAIL  %s\n' "$*" >&2; rc=1; }

    echo "== identity =="
    printf '  image   %s\n' "$(sed -n 's/^IMAGE_VERSION=//p' /usr/share/myosi/version 2>/dev/null)"
    printf '  kernel  %s\n' "$(uname -r)"

    echo "== LUKS bootstrap key =="
    DEV=/dev/disk/by-partlabel/data-luks
    if [ ! -e "$DEV" ]; then
        warn "$DEV not found (not a myosi install, or the pool is not assembled)"
    else
        if cryptsetup luksOpen --test-passphrase \
                --key-file /usr/share/myosi/keys/data.key "$DEV" \
                >/dev/null 2>&1; then
            fail "bootstrap key still unlocks $DEV"
            echo "      add a passphrase/TPM2 slot, then: cryptsetup luksKillSlot $DEV 0" >&2
        else
            pass "bootstrap key no longer unlocks $DEV"
        fi

        echo "  enrolled slots:"
        systemd-cryptenroll "$DEV" 2>/dev/null | sed 's/^/    /' || true
    fi

    if [ -e /efi/keys/data.key ]; then
        warn "bootstrap key present on the unencrypted ESP: rm -f /efi/keys/data.key"
    else
        pass "no bootstrap key on the ESP"
    fi

    echo "== account passwords =="
    ROOT_STATE=$(passwd -S root 2>/dev/null | awk '{print $2}')
    case "$ROOT_STATE" in
        L|LK) pass "root is locked" ;;
        P|PS) warn "root has a usable password — lock it after verifying your own login" ;;
        NP)   fail "root has an empty password" ;;
        *)    warn "could not determine root password state" ;;
    esac

    if command -v homectl >/dev/null 2>&1 && homectl list >/dev/null 2>&1; then
        while IFS= read -r u; do
            [ -n "$u" ] || continue
            case "$u" in NAME|No) continue ;; esac
            [[ "$u" =~ ^[0-9]+$ ]] && continue
            hint=$(homectl inspect "$u" 2>/dev/null | \
                sed -n 's/^[[:space:]]*Passw\. Hint:[[:space:]]*//p')
            case "$hint" in
                *changeme*|*[Dd]efault\ password*)
                    warn "homed user '$u' still advertises the bootstrap password hint"
                    echo "      change it: homectl passwd $u; homectl update $u --password-hint=\"\"" >&2
                    ;;
            esac
        done < <(homectl list 2>/dev/null | awk 'NR>1 && NF>=1 {print $1}')
    fi

    echo "== authselect =="
    if command -v authselect >/dev/null 2>&1; then
        if authselect check >/dev/null 2>&1; then
            pass "authselect configuration valid"
        else
            warn "authselect check failed — review /etc/authselect (README 3a.1)"
        fi
    fi

    echo "== image trust =="
    if image_cert_trusted; then
        pass "image.crt trusted by the kernel (.platform or .machine)"
    else
        warn "image.crt is in neither .platform nor .machine — sysext verity validation may fail (README 3c)"
    fi

    echo "== NVIDIA CDI =="
    if command -v nvidia-ctk >/dev/null 2>&1; then
        if [ -s /var/run/cdi/nvidia.yaml ]; then
            pass "NVIDIA CDI spec present"
        else
            warn "NVIDIA userspace present but no CDI spec — start nvidia-cdi-refresh.service"
        fi
    fi

    echo "== /etc overlay =="
    if mountpoint -q /.etc; then
        dead=$(/usr/local/bin/myosi etc-prune 2>/dev/null | \
            grep -cE '^(identical to image|hides nothing)')
        if [ "${dead:-0}" -gt 0 ]; then
            warn "$dead /etc override(s) no longer override anything — run: myosi etc-prune apply"
        else
            pass "no dead /etc overlay entries"
        fi
    else
        warn "/.etc is not mounted — /etc is not overlay-backed on this boot"
    fi

    echo "== services + storage =="
    FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' ')
    ALLOWED_FAILED="systemd-tpm2-setup.service"
    UNEXPECTED=""
    for u in $FAILED; do
        case " $ALLOWED_FAILED " in *" $u "*) : ;; *) UNEXPECTED="$UNEXPECTED $u" ;; esac
    done
    if [ -n "$UNEXPECTED" ]; then
        warn "unexpected failed units:$UNEXPECTED"
    else
        pass "no unexpected failed units"
    fi

    if command -v btrfs >/dev/null 2>&1 && btrfs filesystem show /var >/dev/null 2>&1; then
        badstats=$(btrfs device stats /var 2>/dev/null | awk '$NF != 0 {print}')
        if [ -n "$badstats" ]; then
            warn "btrfs device errors recorded:"
            printf '%s\n' "$badstats" | sed 's/^/      /' >&2
        else
            pass "btrfs device stats are clean"
        fi
    fi

    echo
    if [ "$rc" -eq 0 ]; then
        echo "security-check: all checks passed."
    else
        echo "security-check: attention required (see WARN/FAIL above)." >&2
    fi
    exit "$rc"
