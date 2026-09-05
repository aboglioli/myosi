# Credential examples

One generic image installs on every host; everything per-host arrives as a
**system credential** staged on that host's ESP, before it has ever booted.

## Credentials on the ESP must be encrypted — and even then, not everywhere

A plaintext `.cred` in `loader/credentials/` **breaks the boot**:
`systemd-tmpfiles-setup*` fails at step `CREDENTIALS`, taking static device
nodes, `/var/log/journal`, dbus-broker, NetworkManager, logind, homed and
sshd with it. systemd routes ESP credentials into the `@encrypted` bucket —
an ESP can be edited offline — so consumers must authenticate them.

Encrypting needs a key that exists before the host does, which rules out
`tpm2` and `host`. That leaves `--with-key=null`, which systemd accepts only
in some configurations. All measured on this image:

| Secure Boot | TPM2 | plaintext | `--with-key=null` |
|---|---|---|---|
| off | present | **breaks boot** | works |
| **on** | **present** | — | **silently rejected** |
| on | absent | — | works |

**ESP credentials therefore do not work on a Secure Boot host with a TPM**,
which is myosi's target profile. The rejection is graceful — the host boots
fine and ignores them — but nothing is applied. For those hosts, bake the
key into a private image with `mkosi.local.conf` `ExtraTrees=` (see the
README chapter), or configure them after the first boot.

```bash
sudo systemd-creds encrypt --with-key=null --name=ssh.authorized_keys.root \
    ~/.ssh/id_ed25519.pub ssh.authorized_keys.root.cred
```

`--name=` must match the filename minus `.cred`.

## A default in the image blocks the ESP override

Where a name exists in both `/usr/lib/credstore/` and the ESP, **the image
default wins** — measured. So the two are mutually exclusive per name:

| name | default shipped? | ESP override? |
|---|---|---|
| `passwd.hashed-password.root` | yes (`changeme`) | no — change it with `passwd` |
| `firstboot.timezone` | yes (`UTC`) | no — `timedatectl` |
| `ssh.authorized_keys.root` | no | **yes** |
| `tmpfiles.extra` | no | **yes** |
| `sysusers.extra`, `home.create.<name>` | no | **yes** |

`tmpfiles.extra` cannot write `/etc/shadow` — SELinux denies it — so it is
not a back door around the first row.

## Staging them

```bash
sudo mount /dev/sdX1 /mnt/esp                    # ESP is partition 1
sudo mkdir -p /mnt/esp/loader/credentials
sudo cp *.cred /mnt/esp/loader/credentials/
sudo umount /mnt/esp
```

Use `loader/credentials/`, not `EFI/Linux/<uki>.efi.extra.d/`: the UKI
filename carries the image version and rotates on every `myosi update`,
which would orphan a per-UKI directory.

This works on a disk that has never booted, which is the whole point —
`/etc` lives on `data-luks`, which `systemd-repart` only creates during the
first boot. The ESP is the one writable surface before that.

## What systemd 259 actually supports

Verified by booting this image, not read from documentation — the upstream
docs describe a newer systemd and list credentials 259 does not have.

| credential | effect |
|---|---|
| `ssh.authorized_keys.root` | root's authorized keys; `tmpfiles` also copies it to `/etc/ssh/authorized_keys.d/root`, making it permanent |
| `passwd.hashed-password.root` | root password, first boot only |
| `passwd.shell.root` | root's shell |
| `firstboot.timezone` | `/etc/localtime` |
| `firstboot.locale`, `firstboot.keymap` | only if `/etc/locale.conf` / `/etc/vconsole.conf` are absent — they are **not**, both ship in RPMs |
| `sysusers.extra` | classic users |
| `home.create.<name>` | homed users |
| `tmpfiles.extra` | arbitrary `tmpfiles.d` lines — the general-purpose lever |
| ~~`firstboot.hostname`~~ | **does not exist in 259** |
| ~~`system.hostname`~~, ~~`system.machine_id`~~ | **not in 259's PID 1** |
| ~~`network.network.*`~~ | generates networkd config; myosi is NetworkManager-only |

## Hostname, and anything else without a credential

`tmpfiles.extra` covers it. `f+` truncates and rewrites, so it beats a file
already baked into the image:

```
f+ /etc/hostname 0644 root root - nas-01
```

Verified: the guest came up as `nas-01`. The same trick sets any file the
image bakes — `/etc/locale.conf`, `/etc/vconsole.conf`, a NetworkManager
keyfile (mode `0600` or NM ignores it).

## When each is read

| credential | consumed by | when |
|---|---|---|
| `ssh.authorized_keys.root` | `sshd` directly, and `systemd-tmpfiles-setup.service` | every boot; the copy makes it permanent |
| `passwd.*`, `firstboot.*` | `systemd-firstboot.service`, `systemd-sysusers.service` | **first boot only** (`ConditionFirstBoot=yes`) |
| `home.create.<name>` | `systemd-homed-firstboot.service` | first boot only |
| `tmpfiles.extra` | `systemd-tmpfiles-setup.service` | every boot, idempotent |

First-boot-only is a feature: it is what stops a credential from clobbering
a later `passwd root` or `hostnamectl`. Those edits land on the `/etc`
overlay upper and survive image upgrades.

`systemd-firstboot` only fills in values that are **unset**. That is why
`/etc/shadow` ships with no root line at all — any line, even a locked
`!*`, makes `passwd.hashed-password.root` unreachable and pins every host
to one password.

## Naming

The filename minus `.cred` is the credential name: printable ASCII, no `/`,
no `:`, not `.` or `..`, at most 255 characters. Per-user settings append
the user — `ssh.authorized_keys.root`, `passwd.hashed-password.alan`,
`home.create.alan`. Multiple SSH keys go in one file, one per line.

## Verifying on the host

```bash
systemd-creds list
systemctl --failed
ls /run/credentials/
```

`systemd-tpm2-setup.service` failing on first boot is expected and
allowlisted in `scripts/vm-test-assertions.sh`. Anything else in
`systemctl --failed` is not.
