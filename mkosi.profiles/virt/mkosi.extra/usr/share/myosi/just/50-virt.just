# virt sysext operator commands.
#
# This file ships INSIDE the virt sysext (/usr/share/myosi/just/ under
# the sysext root) and is overlaid into /usr/share/myosi/just/50-virt.just
# only while the virt sysext is merged. The myosi wrapper discovers it
# by directory scan, so `myosi virt-setup` appears in `myosi --list`
# the moment the sysext is active, and disappears when it isn't.

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
