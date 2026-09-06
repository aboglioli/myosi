# Host LAN bridge. One bridge serves libvirt, podman and incus alike, so it
# lives in the base image rather than in a sysext.

BRIDGE_SETUP := "/usr/libexec/myosi/bridge-setup"

# Create the LAN bridge and enslave the default-route iface (br0; over SSH the link drops 5-30 s).
[group('network')]
bridge-create *args:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    exec {{BRIDGE_SETUP}} create {{args}}

# Show the bridge, its slaves, and its address. Read-only, no root needed.
[group('network')]
bridge-status *args:
    #!/usr/bin/env bash
    set -euo pipefail
    exec {{BRIDGE_SETUP}} status {{args}}

# Remove the bridge and give the physical iface a plain connection back.
[group('network')]
bridge-delete *args:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    exec {{BRIDGE_SETUP}} delete {{args}}
