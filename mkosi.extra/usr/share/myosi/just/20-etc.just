# Inspect and roll back the /etc overlay.
#
# /etc is assembled at boot from the verity-baked factory tree
# (/usr/share/factory/etc, the lower) plus everything this host has changed
# (/.myosi/etc, the upper). The upper IS the answer to "what did I change" —
# no diff pass required, and nothing to forget.
#
# Deletions of factory files show up in the upper as 0:0 character devices
# (overlayfs whiteouts) and directories replaced wholesale carry a
# trusted.overlay.opaque xattr; both need root to inspect.
#
# WHY reset/prune only QUEUE work: the kernel gives an incoherent view of an
# overlay whose upper is edited underneath it — a removed upper file keeps
# serving stale content until the mount is re-established. /etc can only be
# remounted by the initrd, so these recipes stage paths in
# /.myosi/etc.pending and etc-assemble applies them on the next boot,
# before the overlay exists.

[group('etc')]
etc-status:
    #!/usr/bin/env bash
    set -uo pipefail
    state=${MYOSI_STATE:-/.myosi}; etc=${MYOSI_ETC:-/etc}
    upper=$state/etc; factory=${MYOSI_FACTORY:-/usr/share/factory/etc}
    if ! mountpoint -q "$state"; then
        echo "ERROR: $state is not mounted — /etc is not overlay-backed on this boot." >&2
        findmnt -no FSTYPE,SOURCE,OPTIONS "$etc" >&2
        exit 1
    fi
    echo "mode      : $(findmnt -no FSTYPE "$etc")"
    echo "lower     : $factory ($(find $factory -type f 2>/dev/null | wc -l) files, image $(. /usr/lib/os-release; echo $IMAGE_VERSION))"
    echo "upper     : $upper"
    echo "  changed : $(find $upper -type f 2>/dev/null | wc -l) files"
    echo "  deleted : $(find $upper -type c 2>/dev/null | wc -l) factory files whiteouted"
    echo "  dirs    : $(find $upper -mindepth 1 -type d 2>/dev/null | wc -l)"
    q=$state/etc.pending
    [ -f "$q" ] && echo "pending   : $(grep -cve '^\s*$' "$q") reset(s) queued for next boot"
    exit 0

# What has this host changed, relative to the image it runs?
[group('etc')]
etc-list filter="":
    #!/usr/bin/env bash
    set -uo pipefail
    upper=${MYOSI_STATE:-/.myosi}/etc
    [ -d "$upper" ] || { echo "no overlay upper at $upper" >&2; exit 1; }
    cd "$upper" || exit 1
    # -type c is a whiteout: the factory file was deleted on this host.
    find . -mindepth 1 \( -type f -o -type c \) -printf '%y %P\n' 2>/dev/null \
        | sed 's/^f /modified  /; s/^c /deleted   /' \
        | { if [ -n "{{filter}}" ]; then grep -- "{{filter}}" || true; else cat; fi; } \
        | sort -k2

# Content diff of this host's /etc against the factory defaults it runs on.
[group('etc')]
etc-diff path="":
    #!/usr/bin/env bash
    set -uo pipefail
    factory=${MYOSI_FACTORY:-/usr/share/factory/etc}; etc=${MYOSI_ETC:-/etc}
    if [ -n "{{path}}" ]; then
        rel="{{path}}"; rel="${rel#/etc/}"; rel="${rel#/}"
        diff -u --color=auto "$factory/$rel" "$etc/$rel"
        exit $(( $? > 1 ? $? : 0 ))
    fi
    # --no-dereference: /etc carries symlinks into /run and /proc that would
    # otherwise each become a "No such file" line burying the real report.
    diff -rq --no-dereference "$factory" "$etc"
    status=$?
    [ $status -le 1 ] || exit $status

# Which of THIS upgrade's image changes are being shadowed by your overrides?
[group('etc')]
etc-drift:
    #!/usr/bin/env bash
    set -uo pipefail
    dir=${MYOSI_MANIFEST_DIR:-/var/lib/myosi/etc-manifests}
    upper=${MYOSI_STATE:-/.myosi}/etc; factory=${MYOSI_FACTORY:-/usr/share/factory/etc}
    ver=${MYOSI_IMAGE_VERSION:-$(. /usr/lib/os-release; echo "$IMAGE_VERSION")}
    cur="$dir/$ver.sha256"
    if [ ! -f "$cur" ]; then
        echo "no manifest for the booted image yet — run: systemctl start myosi-etc-manifest.service" >&2
        exit 1
    fi
    prev=$(ls -1t "$dir"/*.sha256 2>/dev/null | grep -Fxv "$cur" | head -1)
    if [ -z "$prev" ]; then
        echo "baseline recorded ($(basename "$cur" .sha256)); drift is reportable after the next image upgrade."
        exit 0
    fi
    echo "comparing $(basename "$prev" .sha256) -> $(basename "$cur" .sha256)"
    shadowed=0
    while IFS= read -r rel; do
        a=$(grep -F "  $rel" "$prev" 2>/dev/null | cut -d' ' -f1)
        b=$(grep -F "  $rel" "$cur"  2>/dev/null | cut -d' ' -f1)
        [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ] || continue
        echo "  SHADOWED  $rel  (the image changed it; your override wins)"
        shadowed=$((shadowed+1))
    done < <(cd "$upper" 2>/dev/null && find . -type f -printf '%P\n')
    [ "$shadowed" -eq 0 ] && echo "  nothing shadowed — every image change reached /etc"
    echo "review one with: myosi etc-diff <path>   restore the image default with: myosi etc-reset <path>"

# Queue "give this path back to the factory default", applied at next boot.
[group('etc')]
etc-reset path:
    #!/usr/bin/env bash
    set -euo pipefail
    . /usr/libexec/myosi/lib.sh
    require_root
    state=${MYOSI_STATE:-/.myosi}
    rel="{{path}}"; rel="${rel#/etc/}"; rel="${rel#/}"
    case "$rel" in ''|/*|*..*) echo "ERROR: bad path: {{path}}" >&2; exit 2;; esac
    if [ ! -e "$state/etc/$rel" ]; then
        echo "$rel is not in the overlay upper — it already comes from the image." >&2
        exit 0
    fi
    touch "$state/etc.pending"
    grep -qxF "$rel" "$state/etc.pending" || echo "$rel" >> "$state/etc.pending"
    echo "queued: $rel  (applied on next boot, before /etc is assembled)"

# Drop upper entries that no longer differ from the image (so updates flow again).
[group('etc')]
etc-prune apply="":
    #!/usr/bin/env bash
    set -uo pipefail
    . /usr/libexec/myosi/lib.sh
    state=${MYOSI_STATE:-/.myosi}; upper=$state/etc
    factory=${MYOSI_FACTORY:-/usr/share/factory/etc}; n=0
    tmp=$(mktemp)
    while IFS= read -r rel; do
        # Identical to the factory file: the override is a no-op.
        if [ -f "$factory/$rel" ] && cmp -s "$upper/$rel" "$factory/$rel"; then
            echo "$rel" >> "$tmp"; echo "  redundant   $rel"; n=$((n+1))
        fi
    done < <(cd "$upper" 2>/dev/null && find . -type f -printf '%P\n')
    while IFS= read -r rel; do
        # Whiteout for a file the image no longer ships: nothing left to hide.
        if [ ! -e "$factory/$rel" ]; then
            echo "$rel" >> "$tmp"; echo "  stale w/o   $rel"; n=$((n+1))
        fi
    done < <(cd "$upper" 2>/dev/null && find . -type c -printf '%P\n')
    if [ "$n" -eq 0 ]; then echo "nothing to prune"; rm -f "$tmp"; exit 0; fi
    if [ "{{apply}}" != "apply" ]; then
        echo "$n prunable entr(ies). Re-run as: myosi etc-prune apply"
        rm -f "$tmp"; exit 0
    fi
    require_root
    touch "$state/etc.pending"
    while IFS= read -r rel; do
        grep -qxF "$rel" "$state/etc.pending" || echo "$rel" >> "$state/etc.pending"
    done < "$tmp"
    rm -f "$tmp"
    echo "queued $n reset(s) — applied on next boot"

# Show or clear the queue that etc-assemble consumes at boot.
[group('etc')]
etc-pending action="":
    #!/usr/bin/env bash
    set -uo pipefail
    q=${MYOSI_STATE:-/.myosi}/etc.pending
    if [ "{{action}}" = "clear" ]; then
        . /usr/libexec/myosi/lib.sh; require_root; rm -f "$q"; echo "queue cleared"; exit 0
    fi
    [ -f "$q" ] || { echo "no resets queued"; exit 0; }
    echo "queued for next boot:"; sed 's/^/  /' "$q"
