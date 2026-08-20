# Inspect and undo this host's /etc changes.
#
# /etc is not a filesystem. It is an overlay of two directories:
#
#     lower   /usr/share/factory/etc   the image's defaults, read-only
#     upper   /.etc/etc                what this host changed
#
# Anything nobody touched here is read straight from the image, so it
# updates when the image does. The moment a file is written, overlayfs
# copies it into the upper and this host owns it from then on.
#
# That makes the upper an exact list of local changes — no diffing, and
# nothing to remember to check after an upgrade.

FACTORY := "/usr/share/factory/etc"
UPPER   := "/.etc/etc"

# What has this host changed, compared to the image it runs?
[group('etc')]
etc-list:
    #!/usr/bin/env bash
    set -uo pipefail
    if ! mountpoint -q /.etc; then
        echo "/.etc is not mounted — /etc is not overlay-backed on this boot." >&2
        exit 1
    fi
    # A deleted factory file leaves an overlayfs whiteout in the upper: a
    # character device with major/minor 0:0, not a regular file.
    cd {{UPPER}}
    find . -mindepth 1 -type f -printf 'changed  %P\n'
    find . -mindepth 1 -type c -printf 'deleted  %P\n'

# Show the content difference between /etc and the image's defaults.
[group('etc')]
etc-diff path="":
    #!/usr/bin/env bash
    set -uo pipefail
    if [ -n "{{path}}" ]; then
        rel="{{path}}"; rel="${rel#/etc/}"
        diff -u "{{FACTORY}}/$rel" "/etc/$rel"
    else
        # --no-dereference: /etc has symlinks into /run and /proc, and
        # following them fills the report with "No such file" noise.
        diff -rq --no-dereference "{{FACTORY}}" /etc
    fi
    # diff exits 1 when files differ, which is the normal result here.
    status=$?
    [ $status -le 1 ] || exit $status

# Stop overriding a path, so it follows the image again. Needs a reboot.
[group('etc')]
etc-reset path:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    rel="{{path}}"; rel="${rel#/etc/}"
    case "$rel" in ''|/*|*..*) echo "ERROR: bad path: {{path}}" >&2; exit 2;; esac
    if [ ! -e "{{UPPER}}/$rel" ]; then
        echo "$rel is not overridden here — it already comes from the image."
        exit 0
    fi
    rm -rf "{{UPPER}}/$rel"
    echo "removed $rel from the overlay upper. Reboot to apply."
    echo "Until then /etc/$rel may still show the old content: the kernel"
    echo "does not promise a coherent view of an overlay whose upper was"
    echo "edited underneath it, and only the initrd can remount /etc."

# List overrides that no longer override anything, and offer to drop them.
[group('etc')]
etc-prune apply="":
    #!/usr/bin/env bash
    set -uo pipefail
    . /usr/libexec/myosi/lib.sh
    dead=()
    # An upper file identical to the image's version: overriding nothing.
    while IFS= read -r rel; do
        if [ -f "{{FACTORY}}/$rel" ] && cmp -s "{{UPPER}}/$rel" "{{FACTORY}}/$rel"; then
            dead+=("$rel"); echo "identical to image   $rel"
        fi
    done < <(cd {{UPPER}} && find . -mindepth 1 -type f -printf '%P\n')
    # A whiteout for a file the image no longer ships: hiding nothing.
    while IFS= read -r rel; do
        if [ ! -e "{{FACTORY}}/$rel" ]; then
            dead+=("$rel"); echo "hides nothing        $rel"
        fi
    done < <(cd {{UPPER}} && find . -mindepth 1 -type c -printf '%P\n')

    if [ "${#dead[@]}" -eq 0 ]; then echo "nothing to prune"; exit 0; fi
    if [ "{{apply}}" != "apply" ]; then
        echo
        echo "${#dead[@]} entr(ies) can be dropped. Re-run as: myosi etc-prune apply"
        exit 0
    fi
    require_root
    for rel in "${dead[@]}"; do rm -rf "{{UPPER}}/$rel"; done
    echo "dropped ${#dead[@]} entr(ies). Reboot to apply."
