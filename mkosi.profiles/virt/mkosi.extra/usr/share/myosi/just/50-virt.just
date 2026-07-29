# virt sysext operator commands — ships inside the sysext, so
# `myosi virt-setup` appears only while the sysext is merged (the myosi
# wrapper discovers /usr/share/myosi/just/ by directory scan).

[group('virt')]
virt-setup *args:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    script=/usr/libexec/myosi/virt-setup
    if [ ! -x "$script" ]; then
        echo "ERROR: $script missing — is the virt sysext merged?" >&2
        echo "       Run: sudo myosi extension-enable virt" >&2
        exit 1
    fi
    exec "$script" {{args}}
