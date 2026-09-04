# Credential examples

Every file beside this one is a **template for the ESP**. Copy the ones you
want onto a target disk's EFI System Partition, adding the `.cred` suffix,
and the host picks them up on its next boot:

```bash
sudo mount /dev/sdX1 /mnt/esp                  # ESP is partition 1
sudo mkdir -p /mnt/esp/loader/credentials
sudo cp ssh.authorized_keys.root /mnt/esp/loader/credentials/ssh.authorized_keys.root.cred
sudo umount /mnt/esp
```

The whole point is that this works on a disk that has **never booted**. The
ESP is the only writable surface between `myosi install` and first boot —
`/etc` lives on `data-luks`, which `systemd-repart` does not create until the
machine is already running.

The files here carry no `.cred` suffix so they read as what they are. The
suffix exists only on the ESP, where `systemd-stub` uses it to select files,
and is stripped again on import.

## Precedence

`systemd-stub` packs `$ESP/loader/credentials/*.cred` into a cpio the kernel
unpacks at `/.extra/global_credentials/`; PID 1 imports it into
`/run/credentials/@system/` before any unit runs. Consumers then search
(first match wins):

| | |
|---|---|
| `/run/credentials/@system/` | **what you put on the ESP** |
| `/etc/credstore/` | operator, on the `/etc` overlay upper |
| `/run/credstore/` | |
| `/usr/lib/credstore/` | **the image default** |

So an ESP credential always beats the image default, and an operator can
override either at runtime by writing `/etc/credstore/`.

## What myosi ships as a default

`mkosi.extra/usr/lib/credstore/` — override any of these from the ESP:

| credential | default |
|---|---|
| `firstboot.hostname` | `myosi` |
| `firstboot.locale` | `en_US.UTF-8` |
| `firstboot.timezone` | `UTC` |
| `vconsole.keymap` | `us` |
| `vconsole.font` | `eurlatgr` |
| `passwd.hashed-password.root` | the `changeme` hash |

## When each one is read

| credential | consumed by | when |
|---|---|---|
| `ssh.authorized_keys.root` | `sshd` directly, and `systemd-tmpfiles-setup.service` copies it to `/etc/ssh/authorized_keys.d/root` | every boot; the copy makes it permanent |
| `ssh.authorized_keys.<user>` | `sshd` directly | every boot, **not** persisted |
| `firstboot.hostname` / `.locale` / `.timezone` | `systemd-firstboot.service` | first boot only (`ConditionFirstBoot=yes`) |
| `passwd.hashed-password.root` | `systemd-firstboot.service`, `systemd-sysusers.service` | first boot only |
| `vconsole.keymap` / `.font` | `systemd-vconsole-setup.service` | every boot |
| `network.dns` / `network.search_domains` | `systemd-resolved.service` | every boot |
| `sysusers.extra` | `systemd-sysusers.service` | every boot, idempotent |
| `home.create.<user>` | `systemd-homed-firstboot.service` | first boot only |
| `tmpfiles.extra` | `systemd-tmpfiles-setup.service` | every boot |

"First boot only" is a feature, not a limitation: it is what stops a
credential from clobbering a later `passwd root` or `hostnamectl`. Those edits
land on the `/etc` overlay upper and survive image upgrades.

## Naming rules

The filename minus `.cred` becomes the credential name, and must satisfy
systemd's `credential_name_valid()` — printable ASCII, no `/`, no `:`, not `.`
or `..`, at most 255 characters. `systemd-stub` additionally skips dotfiles
and directories. The convention is a dotted namespace, with the target
appended for per-user settings: `ssh.authorized_keys.root`,
`passwd.hashed-password.alan`, `home.create.alan`.

## What does NOT work here

- **`network.network.*`, `network.link.*`, `network.netdev.*`** — these
  generate `systemd-networkd` configuration, and myosi is NetworkManager-only
  (`networkd` is not installed). Use `tmpfiles.extra` to drop a NetworkManager
  keyfile instead; see `tmpfiles.extra`.
- **Secrets.** The ESP is unencrypted vfat and anyone with the disk can read
  it. Public keys and password *hashes* are fine. Anything genuinely secret
  belongs in `/etc/credstore.encrypted/` with TPM binding, which by definition
  cannot be pre-staged before first boot.
