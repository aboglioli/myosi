#!/usr/bin/env bash
# Assertions run INSIDE a freshly installed myosi VM, over the vsock SSH
# channel opened by vm-boot-test.sh. Everything here is a property of a
# FIRST boot: repart has just built the pool, tmpfiles has run once, and
# nothing has been carried over from an earlier image. That is the whole
# point — an upgraded host keeps directories and SELinux labels from
# whatever version created them, so it can never tell you whether the
# current tmpfiles.d still produces them.
#
# Exits non-zero if any check fails, after running them all, so one run
# reports every problem rather than the first.

set -uo pipefail

PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
check(){ # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}
# SELinux type only — the user/role prefix differs by who created the
# object and is not what policy enforces on.
setype() { ls -Zd "$1" 2>/dev/null | awk '{print $1}' | cut -d: -f3; }

echo "== identity =="
printf '  image   %s\n' "$(sed -n 's/^IMAGE_VERSION=//p' /usr/share/myosi/version 2>/dev/null)"
printf '  kernel  %s\n' "$(uname -r)"

echo "== SELinux =="
check "enforcing"            "Enforcing" "$(getenforce 2>/dev/null)"
# myosi boots with audit=0, so the kernel drops every denial record before
# it can reach the journal: grepping for "avc: denied" returns 0 whether the
# policy is clean or in ruins, which is the most dangerous kind of green.
# Assert the precondition instead, so this reads as "not checked" rather
# than "checked and fine", and the day audit is turned on the count starts
# meaning something.
if grep -qw 'audit=0' /proc/cmdline; then
    printf '  SKIP  AVC denials not auditable (audit=0 on the kernel cmdline)\n'
else
    AVC=$(journalctl -b --no-pager 2>/dev/null | grep -ci 'avc: *denied')
    check "zero AVC denials"     "0"         "$AVC"
fi

echo "== subvolume roots and the paths whose tmpfiles t-lines were removed =="
# /var /home /srv carry no myosi t-line: systemd's own var.conf (q /var)
# and home.conf (Q /home, q /srv) create and label them. /etc keeps one.
check "/var                  var_t"                "var_t"               "$(setype /var)"
check "/home                 home_root_t"          "home_root_t"         "$(setype /home)"
check "/srv                  var_t"                "var_t"               "$(setype /srv)"
check "/etc                  etc_t"                "etc_t"               "$(setype /etc)"
check "/var/log              var_log_t"            "var_log_t"           "$(setype /var/log)"
check "/var/lib              var_lib_t"            "var_lib_t"           "$(setype /var/lib)"
check "/var/cache            var_t"                "var_t"               "$(setype /var/cache)"
check "/var/tmp              tmp_t"                "tmp_t"               "$(setype /var/tmp)"
check "/var/roothome         admin_home_t"         "admin_home_t"        "$(setype /var/roothome)"
check "/var/lib/containers   container_var_lib_t"  "container_var_lib_t" "$(setype /var/lib/containers)"
check "/var/lib/containers/users"                  "container_var_lib_t" "$(setype /var/lib/containers/users)"

echo "== tmpfiles outcomes =="
check "/var/lib/containers/users is 1777" "1777" "$(stat -c %a /var/lib/containers/users 2>/dev/null)"
[ -d /var/log/journal ] && ok "/var/log/journal exists (persistent journal)" \
    || bad "/var/log/journal exists (persistent journal)" "missing — journald is volatile, logs die on reboot"
# NOT "is the journal persistent right now": on the very first boot it
# cannot be. journald flushes to /var/log/journal once, early, and on a
# fresh install /var does not exist yet — repart is still building the pool,
# so tmpfiles creates the directory well after the flush has run and this
# boot lives out its life in /run. Persistence starts at the second boot,
# verified by rebooting a fresh VM. What first boot can honestly assert is
# that the directory was created such that the next boot picks it up.
check "/var/log/journal mode"  "2755"                 "$(stat -c %a /var/log/journal 2>/dev/null)"
check "/var/log/journal group" "systemd-journal"      "$(stat -c %G /var/log/journal 2>/dev/null)"
# Removed entries must NOT reappear.
for p in /var/games /srv/machines /etc/extensions /var/lib/flatpak; do
    [ -e "$p" ] && bad "$p absent (entry was removed)" "still present" || ok "$p absent (entry was removed)"
done
[ -d /srv/users ] && ok "/srv/users exists" || bad "/srv/users exists" "missing"
check "/srv/users is 1777" "1777" "$(stat -c %a /srv/users 2>/dev/null)"

echo "== NoCOW policy =="
nocow() { lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q C && echo yes || echo no; }
check "/var/lib/containers NOT NoCOW" "no"  "$(nocow /var/lib/containers)"
check "/var/tmp is NoCOW"             "yes" "$(nocow /var/tmp)"
check "/var/cache is NoCOW"           "yes" "$(nocow /var/cache)"
# systemd's journal-nocow.conf owns this one, not us.
check "/var/log/journal is NoCOW"     "yes" "$(nocow /var/log/journal)"

echo "== mounts =="
for u in var.mount home.mount srv.mount; do
    check "$u active" "active" "$(systemctl is-active "$u" 2>/dev/null)"
done
check "/etc is an overlay" "overlay" "$(findmnt -no FSTYPE /etc 2>/dev/null)"
check "/ is erofs (verity root)" "erofs" "$(findmnt -no FSTYPE / 2>/dev/null)"

echo "== units =="
# systemd-tpm2-setup fails on first boot (writes the anchor secret, then
# exits 1 on "NvPCRs already initialized"). Tracked separately; allowlisted
# here so this job reports real regressions instead of a known red.
ALLOWED_FAILED="systemd-tpm2-setup.service"
FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | sort | tr '\n' ' ')
UNEXPECTED=""
for u in $FAILED; do
    case " $ALLOWED_FAILED " in *" $u "*) : ;; *) UNEXPECTED="$UNEXPECTED $u" ;; esac
done
[ -z "$UNEXPECTED" ] && ok "no unexpected failed units (failed: ${FAILED:-none})" \
    || bad "no unexpected failed units" "unexpected:$UNEXPECTED"

echo "== containers (only when the profile is present) =="
if command -v podman >/dev/null 2>&1; then
    check "root graphroot is stock" "/var/lib/containers/storage" \
        "$(podman info --format '{{.Store.GraphRoot}}' 2>/dev/null)"
    check "root runroot is stock"   "/run/containers/storage" \
        "$(podman info --format '{{.Store.RunRoot}}' 2>/dev/null)"
else
    echo "  SKIP  podman not in this image (base profile)"
fi

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
