# User management.
#
# Creating a user is a one-time act that cannot happen before first boot:
# /home lives on the data-luks pool, and systemd-repart only creates that
# pool the first time the image boots. So there is nothing to bake into the
# image and no point provisioning at build time — unlike mybox, which is a
# container and can take its user from env vars at start.
#
# The split: these recipes are the operator action, myosi-users.service is
# the upkeep. Creation is one-shot; group membership, subuid ranges and
# linger are re-applied on every boot, so a group that only appears when a
# sysext is merged still lands on the user later.

# storage=homed gives a workstation a per-user LUKS home that unlocks at
# login. The default, classic, gives a server a plain home on the pool with
# linger on, so rootless quadlets start at boot.
#
# Create a user (storage=classic|homed)
[group('users')]
user-create name storage="classic" uid="" groups="" shell="" realname="":
    #!/usr/bin/env bash
    set -euo pipefail
    [ "$EUID" -eq 0 ] || { echo "must be root" >&2; exit 1; }
    name='{{name}}'
    case "$name" in
        ''|*[!a-z0-9_-]*) echo "invalid user name: '$name'" >&2; exit 2 ;;
    esac
    case '{{storage}}' in
        classic|homed) ;;
        *) echo "storage must be classic or homed, got '{{storage}}'" >&2; exit 2 ;;
    esac
    dest="/etc/myosi/users/${name}.user"
    if [ -e "$dest" ]; then
        echo "$dest already exists — edit it, or 'myosi user-forget $name' first" >&2
        exit 1
    fi
    mkdir -p /etc/myosi/users

    # Only fields the operator actually set are emitted. An absent uid lets
    # useradd/homectl pick the next free one rather than baking a number that
    # collides on the next host.
    shell='{{shell}}'
    if [ -z "$shell" ]; then
        shell=/bin/bash
        [ -x /usr/bin/fish ] && shell=/usr/bin/fish
    fi
    args=(--arg n "$name" --arg sh "$shell")
    filter='{userName:$n, homeDirectory:("/home/"+$n), shell:$sh}'
    if [ -n '{{uid}}' ]; then
        args+=(--argjson u '{{uid}}')
        filter="$filter + {uid:\$u, gid:\$u}"
    fi
    if [ -n '{{realname}}' ]; then
        args+=(--arg rn '{{realname}}')
        filter="$filter + {realName:\$rn}"
    fi
    if [ -n '{{groups}}' ]; then
        args+=(--arg g '{{groups}}')
        filter="$filter + {memberOf:(\$g|split(\",\")|map(select(length>0)))}"
    fi
    # `service` is the discriminator user-provision reads back, and it is a
    # real user-record field rather than something myosi invented, so homectl
    # accepts the same file verbatim.
    [ '{{storage}}' = homed ] && filter="$filter + {service:\"io.systemd.Home\"}"

    jq -n "${args[@]}" "$filter" > "$dest"
    chmod 0644 "$dest"
    echo "wrote $dest:"
    sed 's/^/    /' "$dest"

    systemctl enable myosi-users.service >/dev/null 2>&1 || true
    echo "provisioning..."
    /usr/libexec/myosi/user-provision --storage='{{storage}}' "$name"
    echo
    echo "Default password is 'changeme' unless MYOSI_BOOTSTRAP_PASSWORD was set."
    if [ '{{storage}}' = homed ]; then
        echo "Change it with: homectl passwd $name"
    else
        echo "Change it with: passwd $name"
    fi

# Show every declared user and what actually landed on the host.
[group('users')]
user-list:
    #!/usr/bin/env bash
    set -uo pipefail
    printf '%-12s %-8s %-7s %-22s %s\n' NAME STORAGE UID SUBUID GROUPS
    shopt -s nullglob
    seen=" "
    for f in /etc/myosi/users/*.user /usr/share/myosi/users/*.user; do
        name=${f##*/}; name=${name%.user}
        case "$seen" in *" $name "*) continue ;; esac
        seen="$seen$name "
        if homectl inspect "$name" >/dev/null 2>&1; then storage=homed
        elif getent passwd "$name" >/dev/null 2>&1;  then storage=classic
        else storage='(absent)'; fi
        printf '%-12s %-8s %-7s %-22s %s\n' \
            "$name" "$storage" \
            "$(id -u "$name" 2>/dev/null || echo -)" \
            "$(grep "^${name}:" /etc/subuid 2>/dev/null | cut -d: -f2,3 || echo -)" \
            "$(id -nG "$name" 2>/dev/null || echo -)"
    done
    # `if`, not `[ ... ] && echo`: as the recipe's last statement a failing
    # test makes just report the whole recipe as failed.
    if [ "$seen" = " " ]; then echo "(no identities declared)"; fi

# Drops the identity so the boot sweep no longer re-applies it. The account,
# its home and its data are left alone — removing those is deliberately a
# separate, manual act.
#
# Stop managing a user (keeps the account)
[group('users')]
user-forget name:
    #!/usr/bin/env bash
    set -euo pipefail
    [ "$EUID" -eq 0 ] || { echo "must be root" >&2; exit 1; }
    f="/etc/myosi/users/{{name}}.user"
    [ -e "$f" ] || { echo "no such identity: $f" >&2; exit 1; }
    rm -f "$f"
    echo "removed $f — '{{name}}' is no longer re-applied at boot."
    echo "The account still exists. To remove it as well:"
    if homectl inspect '{{name}}' >/dev/null 2>&1; then
        echo "    homectl remove {{name}}"
    else
        echo "    loginctl disable-linger {{name}} && userdel -r {{name}}"
    fi
