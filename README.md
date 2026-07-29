# myosi

Personal atomic, immutable Linux distribution built from raw mkosi + systemd primitives. Signed dm-verity erofs root, A/B sysupdate slots, signed sysexts for optional userspace features (kernel modules included), writable persistent `/etc` as a btrfs subvolume on the encrypted data-luks pool for local host identity. Fedora 44 base. No bootc, no ostree, no rpm-ostree.

The base image is the same on every host. Hostname and local tweaks live in the persistent `/etc` btrfs subvolume on `data-luks`, seeded from the verity-baked `/usr/share/factory/etc` factory tree on first boot. Optional features (desktop, containers, virt, firmware, NVIDIA Turing+, NVIDIA Pascal/Maxwell/Volta legacy, OpenZFS) are added per host by enabling signed sysexts on top of the slim base. Every kernel module shipped in a sysext is signed with `boot.key` so it passes `module.sig_enforce=1` at load.

**See the Design notes and Multi-disk storage runbook appendices below for full architecture, rationale, multi-disk patterns, and milestones.**

---

## Why a second OS?

`myos` (the sibling project) is a bootc/ostree image. It works. It's complex underneath: bootc + ostree + composefs + rpm-ostree all interacting. `myosi` rebuilds the same idea directly on top of upstream systemd primitives:

| Concern | myos (bootc) | myosi (mkosi) |
|---------|--------------|---------------|
| Image format | OCI container | signed disk image (raw) |
| Root integrity | composefs (fs-verity) | dm-verity over erofs (signed Merkle tree) |
| Atomic updates | `bootc upgrade` (OCI pull) | `systemd-sysupdate` (signed artifact pull) |
| `/etc` model | layered via ostree 3-way merge | persistent btrfs subvol on `data-luks`; seeded from verity-baked `/usr/share/factory/etc` factory tree in the initrd by `myosi-etc-seed.service` on first boot |
| Boot chain | shim → GRUB → BLS entries | shim → sd-boot → signed UKI |
| Per-host config | host-specific image variant | persistent `/etc` btrfs subvol on `data-luks` |
| Optional features | host-specific image variant | sysext merged into `/usr` (enabled per host) |
| Distribution | GHCR registry | GitHub Releases (signed `.raw` files) |

Both will coexist for some time. `myos` continues to serve hosts. `myosi` is hardened in parallel and replaces hosts one-by-one when stable.

---

## Architecture at a glance

```
┌─────────────────────────────────────────────────────────────────┐
│  UEFI firmware                                                  │
│   └─ shim (MS-signed) ──── if SecureBoot on, validates next     │
│        └─ systemd-boot (signed with boot.key, accepted via MOK) │
│             └─ UKI (kernel + initramfs + cmdline + os-release,  │
│                     signed as one PE binary with boot.key)      │
│                  └─ initramfs:                                  │
│                       systemd-veritysetup → mount root (RO)     │
│                       systemd-repart → create/grow data-luks    │
│                       myosi-data-attach → unlock /dev/mapper/data│
│                                            + unlock data-N pool │
│                                            + btrfs device scan  │
│                       data-attach seeds /etc from /usr/share/factory/etc      │
│                                  + setfattr etc_t (first boot)  │
│                       sysroot-etc.mount → /sysroot/etc (subvol) │
│                       → switch_root                             │
│                  └─ real root systemd:                          │
│                       var.mount (gpt-auto from Type=var,        │
│                                  DefaultSubvolume=/var)         │
│                       home.mount + srv.mount (btrfs subvols)    │
│                       systemd-sysext → merge /usr extensions    │
└─────────────────────────────────────────────────────────────────┘
```

**Why repart runs in the initrd:** `systemd-repart.service` runs after `sysroot.mount` in the initrd, reads `/usr/lib/repart.d/*.conf` from the initrd cpio image, and creates missing partitions (root-B, verity-B, verity-sig-B, data-luks) or grows the existing data partition to fill the disk. The initrd repart definitions are copied from `mkosi.extra/usr/lib/repart.d/` via `ExtraTrees=`. Running repart in the initrd ensures that `/dev/mapper/data` has full capacity, and that the `/var` + `/etc` subvolumes exist on it, before `sysroot-etc.mount` fires (in the initrd) and `var.mount` is auto-generated (in the main system) — no manual `cryptsetup resize` or `btrfs filesystem resize max` step needed on first boot.

**Why there is no `/etc/fstab` or `/etc/crypttab`:** The sealed erofs `/etc` is wiped after its factory contents are snapshotted to `/usr/share/factory/etc` (the factory tree `myosi-etc-seed.service` copies into the empty `/etc` subvol on first boot, between `sysroot-etc.mount` and pivot). Static crypttab/fstab would be wrong for multi-disk hosts (global PARTLABEL selection races with attached myosi disks) and cannot handle the `data-N` pool members. The initrd `myosi-data-attach` service discovers and unlocks the primary data partition + any `data-N` pool members directly; `sysroot-etc.mount` mounts the `/etc` subvol before pivot; explicit `var.mount`, `home.mount`, and `srv.mount` units mount the sibling subvols in the main system (each with `BindsTo=dev-mapper-data.device`, `Options=defaults,noatime,compress=zstd:3,subvol=/<name>`).

**Partition layout (target disk after install — total ~12 GiB minimum):**
```
ESP                  vfat   2G       bootloader + UKIs (InstancesMax=2 → ~2× 256 MiB UKI today). No /boot partition — kernel lives inside each signed UKI on the ESP, sd-boot reads /EFI/Linux/*.efi directly. FAT required by UEFI.
root-a               erofs  5G        signed read-only root (slot A; fixed size for A/B parity)
root-a-verity        verity 64M       Merkle tree for root-a
root-a-verity-sig    cms    16K       signature of root hash
root-b / verity / sig             same triple (slot B; empty placeholder until first sysupdate, SplitName=- to skip in --split=yes)
data                 luks2+btrfs      grows to fill disk; /var, /home, /srv subvolumes
```

Slot sizes are pinned (`SizeMinBytes=SizeMaxBytes`) so systemd-repart's build and `--split=yes` passes agree on verity hash offsets — without that the verity-sig partition ends up empty and the build fails. 5G slots hold ~2.2 GiB of base root content today, leaving room to embed `containers` / `virt` / `firmware` sysexts directly into the verity-baked root in future without changing the partition layout.

**Image artifacts produced by `just build`** (every name carries the build `ARCH`, e.g. `x86-64` or `arm64`, set by `Output=%i_%v_%a` on every sub-image):
| Artifact | Purpose |
|----------|---------|
| `myosi_VERSION_ARCH.raw.zst` | Full disk image: ESP + signed root A+B + data |
| `myosi_VERSION_ARCH.efi` | Signed UKI for sysupdate to drop into ESP |
| `myosi_VERSION_ARCH_<ROOT_UUID>.root.raw.zst` | Signed root partition for sysupdate. The PartitionUUID embedded in the filename is the first 16 bytes of the dm-verity root hash (Discoverable Partitions Spec). Captured at apply time via the `@u` wildcard in `10-root.transfer`. Auto-renamed from the bare `myosi_VERSION_ARCH.root.raw.zst` by `scripts/stage-artifacts.sh` (invoked by both `just build` and CI after `mkosi build`). |
| `myosi_VERSION_ARCH_<VERITY_UUID>.verity.raw.zst` | Verity hash partition for sysupdate. UUID is the LAST 16 bytes of the root hash. Same `@u` mechanism. |
| `myosi_VERSION_ARCH.verity-sig.raw.zst` | Verity signature partition |
| `containers_VERSION_ARCH.raw` | Sysext: Podman, Distrobox, Compose, Skopeo, Incus + container-selinux baked into base policy |
| `desktop_VERSION_ARCH.raw` | Sysext: Niri, fonts, audio, apps |
| `firmware_VERSION_ARCH.raw` | Sysext: full linux-firmware blob |
| `virt_VERSION_ARCH.raw` | Sysext: libvirt, qemu, vfio, virt-manager |
| `nvidia_VERSION_ARCH.raw` | Sysext: NVIDIA `current` (595.x open kernel modules, Turing+ — RTX 16xx/20xx/30xx/40xx/50xx). All `nvidia*.ko` signed with `boot.key`. |
| `nvidia-580xx_VERSION_ARCH.raw` | Sysext: NVIDIA `580xx` legacy proprietary modules (Maxwell / Pascal / Volta — GTX 9xx/10xx, Titan V). All `nvidia*.ko` signed with `boot.key`. |
| `zfs_VERSION_ARCH.raw` | Sysext: OpenZFS (`zfs-2.4.2` today) — `zfs.ko` + `spl.ko` signed with `boot.key`, plus userspace (`zfs`, `zpool`, `zed`, libraries, `zfs-dracut`, `python3-pyzfs`). Built from the upstream tarball, no RPMFusion / zfsonlinux.org repo dependency. |
| `mybox_VERSION_ARCH.raw` | Sealed verity-erofs nspawn DDI. Drop into `/var/lib/machines/`, start via `machinectl start mybox`. Optional, opt-in via `myosi machine-enable mybox`. |

Each `*_VERSION_ARCH.raw` sysext carries verity + signature partitions. Every kernel module shipped in those sysexts is signed against `boot.key` so `module.sig_enforce=1` in the UKI cmdline accepts them when the kernel `.platform` keyring has `boot.crt` enrolled (UEFI db on qemu, MOK on hardware).

Boot trust uses `keys/boot.crt` enrolled as a MOK so shim accepts sd-boot and the UKI. Image trust uses `keys/image.crt`, enrolled into UEFI db (qemu via OVMF_VARS) or as a MOK (hardware) so the kernel `.platform` keyring contains it at init — dm-verity and sysexts validate signatures directly against `.platform`.

---

## Repository layout

```
myosi/
├── README.md                # this file (all install + design docs inline)
├── mkosi.conf               # main image (base) config
├── mkosi.conf.d/            # auto-generated package + ID conf drop-ins
├── mkosi.images/            # sub-image definitions
│   ├── base-tree/           # shared base for sysext BaseTrees=
│   ├── initrd/             # custom initrd extension (Include=mkosi-initrd)
│   ├── desktop/             # Niri sysext
│   ├── virt/                # libvirt/qemu/vfio sysext
│   ├── containers/          # podman/distrobox/compose/skopeo/incus sysext
│   ├── nvidia/              # 595.x driver sysext (Turing+, open kmod)
│   ├── nvidia-580xx/        # 580.x driver sysext (Pascal/Maxwell/Volta, proprietary)
│   └── zfs/                 # OpenZFS sysext (built from upstream tarball)
├── mkosi.shared/            # shared sub-image config + build helpers
│   ├── sysext.conf          # symlinked as mkosi.conf.d/00-shared.conf in each sysext
│   ├── sysext-build.sh      # atoms: stage_sysext_policy, strip_to_sysext_layout
│   ├── kmod-build.sh        # generic out-of-tree kmod helpers
│   ├── nvidia-build.sh      # NVIDIA-specific: rpmbuild kmod, sign with boot.key, modprobe.d
│   └── zfs-build.sh         # OpenZFS-specific: tarball → SRPM → rpmbuild → sign
├── mkosi.extra/             # files copied verbatim into the image
│   ├── etc/                 # /etc baseline (shadow, subuid, sshd_config.d, etc.)
│   └── usr/                 # /usr baseline (sysctl.d, udev rules, sysupdate, libexec, ...)
├── mkosi.repart/            # build-time partition defs (4: ESP + root-A + verity-A + verity-sig-A) — mkosi auto-discovers
├── mkosi.extra/usr/lib/repart.d/ # runtime/first-boot expansion layout (8 partitions: build set + root-B + verity-B + verity-sig-B + data-luks)
├── mkosi.prepare            # script run before package install (cert copy)
├── mkosi.postinst           # script run after package install (service enable, version stamp)
├── packages/                # build metadata, e.g. pinned-kernel.txt for NVIDIA sysext iteration
├── keys/                    # signing key staging directory (gitignored key material)
├── scripts/                 # host-side build/CI helpers (generate-keys, decode-keys,
│                              stage-artifacts, sysupdate-manifest)
├── .github/workflows/      # GitHub Actions release workflow
└── justfile                 # all developer + operator commands
```

---

## Runtime layout + invariants (read this first)

This section captures the load-bearing paths, ordering rules, and
known footguns that drove the recent round of fixes. It deliberately
stays generic — the canonical implementation lives in the source
files referenced; this is the operator/contributor map.

### Where things live

| Path | Purpose | Owner / mutability |
|------|---------|---------------------|
| `/usr` | Verity-erofs root (signed, dm-verity protected). Sysexts merge on top via overlayfs at boot. | Read-only at runtime. Updated atomically by `sysupdate` swapping the A/B slot. |
| `/usr/share/myosi/` | All myosi-shipped data: signing keys, version metadata, baseline sysext images, fleet SSH keys. Verity-immutable. | Image-coupled. Changes atomically with each image upgrade. |
| `/usr/share/myosi/extensions/` | Baseline sysext `.raw` files that ship inside the image (none currently; infrastructure kept for future baselines). NOT a path systemd-sysext discovers from — see below. | Image-coupled. |
| `/usr/lib/extensions/` | Documented by systemd as a sysext location but in practice systemd-sysext does NOT scan it for discovery on F44 / systemd 259. Do not bake new sysexts here. | (avoid) |
| `/etc` | Persistent btrfs subvolume on `data-luks` (`/dev/mapper/data` `subvol=/etc`). Seeded from the verity-baked `/usr/share/factory/etc` factory tree on first boot by `myosi-etc-seed.service` (initrd; `cp -a --reflink=auto /sysroot/usr/share/factory/etc/. /sysroot/etc/` + `setfattr etc_t /sysroot/etc`). Every write lands directly in the subvol and persists across image upgrades. | Operator-mutable. |
| `/usr/share/factory/etc/` | The verity-baked factory `/etc` tree. `mkosi.finalize` snapshots the build-settled `/etc` here then wipes the sealed-root `/etc` mountpoint. Read by `myosi-etc-seed.service` only on first boot — once the subvol is populated, new files added to `/usr/share/factory/etc` in later images are NOT auto-merged into `/etc` (operator owns `/etc` after first boot, bootc/ostree-style). Use `diff -ruN /etc /usr/share/factory/etc` to spot drift after upgrades. | Image-coupled. |
| `/var/lib/extensions/` | The discovery path systemd-sysext actually scans. Operator-installed sysexts (via sysupdate or manual drop) live here as regular files. Image-baked baselines are materialized here as symlinks → `/usr/share/myosi/extensions/` by `sysext-baked-sync`. | Operator-mutable + sync-managed. |
| `/etc/extensions/`, `/run/extensions/` | Additional sysext discovery paths (rare). | Operator-mutable. |
| `/srv`, `/mnt` → `var/mnt` | `/srv` is a dedicated btrfs subvolume from `data-luks`; `/mnt` is symlinked into writable `/var`. | `/srv` and `/mnt` targets are operator-mutable. |
| `/var/lib/machines/` | Per-machine btrfs subvolumes for `systemd-nspawn` containers managed by `machinectl`. | Operator-mutable. |
| `/usr/libexec/myosi/` | Shipped helper scripts (`sysext-modules-refresh`, `homed-user-provision`, `sysext-baked-sync`, `install`, `lib.sh`). | Image-coupled. |

### systemd-sysext discovery, multi-version merge, and baselines

`systemd-sysext` on Fedora 44 / systemd 259 scans these paths for `.raw`
images in this order: `/etc/extensions/`, `/run/extensions/`,
`/var/lib/extensions/`, plus `/.extra/sysext/` in the initrd. **It
does NOT scan `/usr/lib/extensions/` or `/usr/share/myosi/extensions/`.**
Empirical observation, not documentation.

It also does NOT auto-select the latest version when multiple raws of
the same logical sysext are present. ALL of them get merged in
overlay order. Version arbitration is `sysupdate`'s job — sysext
itself just unions whatever it finds. So letting stale `name_V1.raw`
sit alongside `name_V2.raw` in the discovery dir means the merged
`/usr` has overlapping contents from both layers, with hard-to-predict
precedence.

myosi handles this with a two-tier model:

1. **Image-baked baselines** live at `/usr/share/myosi/extensions/`
   (verity-immutable, atomic swap on image upgrade — no `/etc`
   overlay copy-up).
2. **`sysext-baked-sync`** runs as `ExecStartPre=` of
   `systemd-sysext.service` on every boot and every `systemd-sysext
   refresh`. It symlinks each baked raw into `/var/lib/extensions/`
   and removes stale-version + dangling symlinks left over from
   previous image versions.
3. **Operator-installed raws** (sysupdate-fetched, manually-dropped)
   live in `/var/lib/extensions/` as regular files. The sync script
   never touches regular files — operator's content is preserved.

This decouples "what ships with the image" (baselines) from "what the
operator added or updated" (regular files), while keeping a single
discovery path that systemd-sysext actually scans.

### Kernel-module sysexts + the depmod overlay

Kmod-shipping sysexts (`nvidia`, `nvidia-580xx`, `zfs`) deliver
`.ko` files at `/usr/lib/modules/<KVER>/extra/<sysext>/`. mkosi's
sysext sealer **strips** `modules.dep`, `modules.alias`, etc. from
each sysext at build time because those files also exist in
`kernel-modules-core` in the base; without that strip every sysext
overlay would shadow the base index with its own partial copy and
modprobe would only find that sysext's modules.

The host-side counterpart is `/usr/libexec/myosi/sysext-modules-refresh`:

1. Stack a tmpfs overlay on `/usr/lib/modules/<KVER>/`.
2. Run `depmod -a` in the overlay so the regenerated indices cover
   every merged sysext's kmod tree.
3. **In the same process**, walk every `modules-load.d/*.conf` entry
   from `/etc`, `/run`, and `/usr/lib` (de-duplicated by basename,
   matching systemd-modules-load priority) and call `modprobe`
   directly.

Why modprobe runs inside sysext-modules-refresh instead of being deferred to
`systemd-modules-load.service`: when a *separate* process spawns
immediately after `depmod -a` writes the new `modules.dep`, libkmod's
initial scan can race against tmpfs-overlay dentry-cache
invalidation. Observed on real boots as
`systemd-modules-load: Failed to find module 'nvidia_drm'`
followed by a working `modprobe nvidia_drm` at the shell seconds
later — same kernel, same overlay, same indices. Loading from the
same shell that just finished `depmod` is race-free.

### The /etc factory-seed footgun

`/etc` is a persistent btrfs subvolume on `data-luks`. On first boot
`myosi-etc-seed.service` (initrd) copies the verity-baked `/usr/share/factory/etc/`
factory tree into the empty subvol. On every subsequent boot the
unit's `ConditionDirectoryNotEmpty=!/sysroot/etc` gate is FALSE
(subvol is non-empty) → unit is skipped. The seed is genuinely
one-shot — image upgrades do NOT re-merge new factory files.

What this means at image upgrade time:

- Operator-modified `/etc` files are preserved across image upgrades
  (the subvol survives image swaps untouched).
- New files added to `/usr/share/factory/etc/` in the new image are **NOT** auto-
  copied into `/etc`. Operator owns `/etc` after first boot — same
  semantics as bootc / ostree atomic distros. Run
  `diff -ruN /etc /usr/share/factory/etc` after an upgrade to spot files you might
  want to pull in by hand.
- Files removed from `/usr/share/factory/etc/` in the new image LEAVE their copy in
  `/etc` behind. If the old name now means something else (logical
  rename, format change), the stale copy is on the operator to clear.

Concrete bite (carried over from the retired overlay model): an old
image baked the fleet-keys sysext under `/usr/share/factory/etc/extensions/`. After
upgrading to a newer image that no longer bakes there, the stale
`.07` raw is still resident at `/etc/extensions/` — `sysext-baked-sync`
prevents it from re-merging via `/var/lib/extensions/`, but a manual
`rm -rf /etc/extensions/*.raw` clears the file itself.

Rules of thumb:

- Never bake versioned content under `/usr/share/factory/etc/` if image upgrades
  ship different versions of the same logical file. Use
  `/usr/share/myosi/` or `/usr/lib/` instead — those paths sit under
  verity-erofs with no operator-mutable copy above them, so image
  upgrade rotates the content atomically.
- `confext` (a separate `/etc` overlay backed by image-shipped raws)
  is **dormant by default** on myosi — `systemd-confext.service` is
  not masked, not preset-enabled. Stock myosi prefers the persistent
  `/etc` subvol + sysexts for `/usr`-extending content + portable
  services for self-contained services with their own `/etc`
  namespace. Operators who later want confext can
  `systemctl enable --now systemd-confext.service` without fighting
  a hard mask. Reconciliation rules between the persistent `/etc`
  and a confext overlay would need a design pass first (deny order,
  copy-up behavior, sysupdate phase handoff).

### Boot path summary

```
firmware → shim → systemd-boot → UKI (signed; kernel + initrd + cmdline + os-release)
   initrd: systemd-veritysetup → mount root RO
           systemd-repart → create missing partitions + grow data-luks to fill disk
                          + create /etc and /var subvolumes inside data-luks btrfs
           myosi-data-attach → find Type=var on same disk as root, unlock as /dev/mapper/data
                              + unlock any data-N pool members from any disk
                              + btrfs device scan to register all pool members
           sysroot-etc.mount → /sysroot/etc (btrfs subvol=/etc; NOT an overlay)
           myosi-etc-seed → cp -a /sysroot/usr/share/factory/etc/. /sysroot/etc/ + setfattr etc_t
                            (first boot only; ConditionDirectoryNotEmpty=!/sysroot/etc)
           → switch_root
   real root: var.mount + home.mount + srv.mount (explicit units, all
                BindsTo=dev-mapper-data.device, Before=local-fs.target)
              systemd-sysext → merge /usr extensions

### Modern-kernel sysctl + module ordering

`/usr/lib/sysctl.d/50-myosi-performance.conf` is tuned for current
kernels (EEVDF-era):

- **Removed knobs are NOT shipped.** `kernel.sched_latency_ns`,
  `sched_min_granularity_ns`, `sched_wakeup_granularity_ns` are gone
  in Linux 6.6+. `kernel.unprivileged_userns_clone` is gone in 5.10+.
  Listing them produces `No such file or directory` errors at every
  boot.
- **`nf_conntrack_max` requires the module loaded first.** Without a
  paired `modules-load.d` entry the sysctl path doesn't exist when
  sysctl runs and the line silently fails. `50-myosi-conntrack.conf`
  loads `nf_conntrack` early to fix this.
- Tuning otherwise tracks Bazzite / CachyOS / Nobara defaults for
  desktop + gaming + container workloads (zRAM-friendly swappiness,
  BBR, TFO, bufferbloat caps).

### Sysext-introduced group memberships

Groups owned by sysext-shipped packages (`libvirt` from libvirt-daemon,
`incus-admin` from incus) are **NOT pre-declared in base** and **NOT
listed in the base homed credential's `memberOf`**. The base sysusers
file and homed record only carry groups that always exist on a base
host (`wheel`, `video`, `render`, `input`, `kvm`).

How sysext-introduced groups get the default user added (fully
decoupled — no base-image edits needed when adding a new sysext):

1. The sysext's own RPM ships a `sysusers.d` entry that creates the
   group (e.g. Fedora's libvirt-daemon ships
   `/usr/lib/sysusers.d/libvirt.conf` with `g libvirt -`). When the
   sysext merges, `systemd-sysext.service` ExecStartPost re-runs
   `systemd-sysusers` which processes that file and creates the
   group on the host.

2. The sysext ALSO ships a one-line drop-in at
   `/usr/share/myosi/user-groups.d/<sysext>.conf` listing the group
   names the default user should join when this sysext is active.
   Example from the virt sysext:
   ```
   # virt sysext: user runs virsh / virt-install
   libvirt
   ```
   This file lives ONLY in the sysext's payload — present in `/usr`
   when merged, absent otherwise. The base image ships nothing in
   this directory.

3. `/usr/libexec/myosi/homed-user-provision` (phase 2) reads every
   `*.conf` in that drop-in directory, dedups the requested group
   names, and for each one currently present in NSS calls
   `gpasswd -a user <group>`. The membership lands in
   `/etc/group` (persistent btrfs subvol on data-luks) and
   is picked up at next login.

4. The binder runs at two trigger points: at boot via
   `myosi-homed-user@user.service` (templated unit, ordered
   After=systemd-homed.service so the varlink interface is up) AND
   from `refresh_sysext` in `lib.sh` (after every live
   `systemd-sysext refresh`, via `systemctl start
   myosi-homed-user@user.service`).

Adding a new feature that needs the default user in a new group is
a one-step change: ship `/usr/share/myosi/user-groups.d/<name>.conf`
in `mkosi.profiles/<name>/mkosi.extra/`. The matching
`mkosi.images/<name>/mkosi.conf` already pulls the profile's tree
via `ExtraTrees=../../mkosi.profiles/<name>/mkosi.extra:/`, so the
snippet ships in both the profile-baked and standalone-sysext build
paths from a single source. Base image untouched.

Trade-off:

- Base hosts have a clean group set — no dangling references to
  packages that aren't installed.
- Enabling a sysext automatically adds the user to its groups at
  the next refresh (or boot), no operator intervention.
- Disabling a sysext doesn't strip stale `/etc/group` entries — the
  membership stays until manually pruned, which is harmless (the
  group itself is gone, no enforcement happens).

### Versioned artifact paths

| Where | Convention |
|---|---|
| `/usr/share/myosi/version` | Image metadata (name, version, build date, git commit, Fedora release, kernel uname). NOT a bootc reference — myosi assembles from RPMs directly. |
| `/efi/EFI/Linux/myosi_<VER>_<ARCH>.efi` | UKIs. `InstancesMax=2` keeps two on the ESP for rollback. |
| `/var/lib/sysupdate/` | sysupdate's local staging dir for fetched root/verity/UKI artifacts before they land in their target slots. |
| `/var/lib/extensions/<name>_<VER>_<ARCH>.raw` | sysext discovery — either a symlink to baseline or an operator-installed regular file. |

### Enabling units without presets: `Wants=`, not `Upholds=`

myosi never runs `systemctl preset-all`, and `/etc` enable symlinks do
not survive an image rebuild — so a package's `[Install] WantedBy=` is
inert. The stand-in is a target drop-in under `/usr` (rides the sysext,
applies fleet-wide, needs no writable `/etc`):

```ini
# /usr/lib/systemd/system/multi-user.target.d/50-myosi-<feature>.conf
[Unit]
Wants=some-thing.service
```

**Use `Wants=`.** `Upholds=` is not a stronger `Wants=` — it is a
*continuous assertion* ("keep this unit active as long as I am"),
re-evaluated every time the unit goes inactive, whereas `Wants=` is a
job queued once and never revisited. On the wrong unit that is an
infinite restart loop.

`Upholds=` is only correct for units that **stay active once started**:
`.socket` units, long-running daemons, `Type=oneshot` with
`RemainAfterExit=yes`. Two shapes end up inactive and therefore loop:

1. **`Type=oneshot`, `RemainAfterExit=no`** — returns to `inactive` the
   instant it *succeeds*, so success is itself the restart trigger.
2. **Any failable `Condition*=`** — a condition-skipped start leaves the
   unit `inactive`; `RemainAfterExit=yes` does not help, it only applies
   to a start that actually ran. A "self-gating" unit is therefore not a
   clean no-op under `Upholds=`, it is a busy-loop.

Both were live on a deployed host, same boot:

| Unit | Shape | Starts in 4.8 h |
|---|---|---|
| `nvidia-cdi-refresh.service` | oneshot, `RemainAfterExit=no` | 27,380 (84k journal lines) |
| `flatpak-setup.service` | `ConditionPathExists=!…/flatpak-setup.done` | ~29k condition-skips |

The journal signature — and it means the loop is *sustained*, not over
("too often recently" is pid1's own Upholds throttle; it never gives up):

```
<unit>: Unit needs to be started because active unit multi-user.target
upholds it, but not starting since we tried this too often recently.
Will retry later.
```

To see it yourself — scratch units in the *user* manager, no root:

```bash
printf '[Unit]\nDescription=probe\n[Service]\nType=oneshot\nRemainAfterExit=no\nExecStart=/usr/bin/logger -t looptest RAN\n' \
    > ~/.config/systemd/user/looptest-oneshot.service
printf '[Unit]\nWants=looptest-oneshot.service\n'    > ~/.config/systemd/user/looptest-w.target
printf '[Unit]\nUpholds=looptest-oneshot.service\n'  > ~/.config/systemd/user/looptest-u.target
systemctl --user daemon-reload

systemctl --user start looptest-w.target   # 1 run, then inactive, stays put
systemctl --user start looptest-u.target   # 10+ runs in 12 s, still retrying

journalctl -t looptest --no-pager | grep -c RAN
rm ~/.config/systemd/user/looptest-*; systemctl --user daemon-reload
```

**Ordering caveat.** `Wants=` carries no ordering, so a unit could in
principle run before a sysext-shipped binary exists and be
condition-skipped with nothing to retry it. It cannot happen here:
`systemd-sysext.service` is ordered at `sysinit.target`, which completes
before `multi-user.target` begins (~9 s of margin on metal). Where a
unit also ships a `.path` watcher, that is the designed recovery path
for a late merge or `systemd-sysext refresh` — which is why upstream
ships both a `.path` and a `.service` with `WantedBy=`. `Upholds=`
overrode that design rather than complementing it.

**Do not "fix" a loop by removing the start-rate limit.** `5`/`10s`
parks a looping unit in `failed` after two seconds — that is the
diagnosis, not the problem. Setting `StartLimitIntervalSec=0` on the
nvidia drop-in removed the only brake and turned a visible failure into
27k silent restarts. Need headroom for a real burst? Raise the burst,
keep the window bounded.

### Service hygiene

A handful of small drop-ins exist because upstream defaults misfire
on this layout. Generic summary so you know what to look for:

- `systemd-sysext.service` carries two drop-ins: `15-myosi-baseline-sync.conf`
  (ExecStartPre to materialize baselines) and `10-myosi-rerun-sysinit.conf`
  (ExecStartPost to re-run sysext-modules-refresh / sysusers / binfmt /
  sysctl / tmpfiles after a sysext merge so the sysext-shipped
  config drops are processed).
- `myosi-homed-user@.service` is a templated oneshot that runs
  `/usr/libexec/myosi/homed-user-provision %i` to create the homed
  record from `/usr/share/myosi/users/<name>.user` and bind the user
  to active sysext groups. Decoupled from `systemd-homed.service`
  ExecStartPost (Type=notify on homed used to mask provisioning
  failures because READY=1 fires before ExecStartPost runs). Preset
  enables `myosi-homed-user@user.service`; add a user by
  dropping `/usr/share/myosi/users/<name>.user` and
  `enable myosi-homed-user@<name>.service` to the preset.
- `nvidia-cdi-refresh.service` ships `10-myosi-no-rate-limit.conf`
  (`StartLimitIntervalSec=10s` + `StartLimitBurst=20`) — its path watcher
  fires twice per `sysext-modules-refresh` run, so the default 5-in-10s
  limit produced spurious failures. The window stays bounded on purpose:
  the old `StartLimitIntervalSec=0` hid a 27k-restart `Upholds=` loop.
  See [Enabling units without presets](#enabling-units-without-presets-wants-not-upholds).
- `systemd-repart.service` carries `10-myosi.conf` whitelisting
  exit code 1 — the steady-state data partition has no upper size
  cap, so repart always exits 1 with "can't fit", which is fine.

### Recent fixes (generic summary)

The above paths and ordering rules were each settled by a specific
fix in this development cycle. Quick index:

- Baseline sysext location moved from `/usr/lib/extensions/` to
  `/usr/share/myosi/extensions/` after observing that systemd-sysext
  does not discover from `/usr/lib/extensions/`. Symlink sync into
  `/var/lib/extensions/` replaces the discovery shortfall.
- Stale `/etc/extensions/*.raw` files from the earlier
  `/usr/share/factory/etc/extensions/` bake-in approach are an upgrade-time
  pitfall — operators on long-lived hosts may need to
  `rm -rf /etc/extensions/*.raw` once after upgrading past that
  change.
- The `/etc` overlay (lowerdir=`/usr/share/factory/etc`, upperdir=`/var/etc`) was
  retired in favor of a real persistent btrfs subvol seeded from
  `/usr/share/factory/etc` via `myosi-etc-seed.service`. This fixed three issues at once: the
  `var.mount FAILED unmount at shutdown` line (PID 1 was holding the
  overlay open on `/var/etc`), the SELinux first-boot upperdir-context
  caching race, and the initrd-side `setfattr` pre-seed for the
  overlay upperdir. The `myosi-firstboot-relabel.service` first-boot
  oneshot was retired along with it.
- `nvidia_drm` was silently absent at boot until kernel-module
  loading was pulled into the same shell process that runs
  `depmod -a`.
- `systemd-modules-load` is intentionally not called as an
  ExecStartPost fallback in the sysext drop-in. The duplicate
  invocations confused operators with spurious "Failed to find
  module" lines while `lsmod` showed the modules loaded.
- `/srv` is a dedicated btrfs subvolume from `data-luks`; `/mnt`
  remains a symlink into `/var` for operator-mounted filesystems.
- The `version` file no longer claims a bootc base image — myosi
  builds from RPMs via mkosi, not from an OCI base.

---

## Installing to real hardware

### Step 1 — Build and flash

```bash
# Developer host
just build                       # see Quickstart for dev/full modes

# Flash USB installer — same install script handles USB and internal disk
just install /dev/sdX            # safety-checked dd of build/myosi_<calver>.raw
```

### Step 2 — First boot on target

Boot the target hardware from USB. From the live environment:

```bash
sudo just install /dev/nvme0n1   # writes the same image to the internal disk
```

First boot of the installed system runs:

- `systemd-repart` in the initrd creates and grows `data-luks` to fill the disk, formats it as LUKS2 + btrfs, creates `/var`, `/etc`, `/home`, and `/srv` subvolumes (`FactoryReset=yes` + `Encrypt=key-file`)
- `myosi-data-attach.service` unlocks `/dev/mapper/data` (key-file first, then TPM2/passphrase fallback) + unlocks present `data-N` pool members + runs `btrfs device scan` + seeds the empty `/etc` subvol from `/sysroot/usr/share/factory/etc` + `setfattr etc_t` on the subvol root
- `sysroot-etc.mount` mounts the `/etc` subvolume before pivot (`/var`, `/home`, `/srv` mount post-pivot — `var.mount` is gpt-auto-generated, `home.mount` and `srv.mount` ship explicitly)
- `myosi-homed-user@user.service` calls `homed-user-provision`, which runs `homectl create` from `/usr/share/myosi/users/user.user` and materializes the LUKS-backed home (default password `changeme`, see §3a.1)
- `systemd-firstboot` (locale/timezone/etc pre-baked, no-op)

### Step 3 — Post-install runbook

Run these steps after the first successful boot. The base image is identical on every host; this section turns it into a usable machine by setting local credentials, growing mutable storage, enrolling trust anchors, and enabling host-specific extensions.

#### 3a. Change passwords and set hostname

`user` ships with `changeme`. `root` ships locked. `user` is
managed by `systemd-homed` (see §3a.1) — `homectl passwd` is the
homed-aware way to change the password.

```bash
sudo passwd root             # sudo asks for user's current password: changeme
homectl passwd user     # change user's password (re-keys LUKS slot on TPM2 hosts)
sudo hostnamectl hostname <hostname>
```

The image never ships a usable root password.

#### 3a.1. User management with systemd-homed

Interactive users on myosi are owned by `systemd-homed`. The user
record ships as a declarative JSON file at
`/usr/share/myosi/users/<name>.user` (UID, shell, supplementary
groups, hashed password — NO secret/storage/diskSize, those are CLI
flags). `myosi-homed-user@<name>.service` runs
`/usr/libexec/myosi/homed-user-provision <name>` on first boot,
which calls `homectl create --identity=<file> --storage=luks
--disk-size=3G --luks-extra-mount-options=defcontext=...` with the
bootstrap password fed via `PASSWORD` / `NEWPASSWORD` env vars.
After creation, homed registers the record in its private database
at `/var/lib/systemd/home/` and `homectl inspect` gates re-runs of
the script. `systemd-userdbd` resolves homed-managed users via NSS.

**Why env vars instead of `secret.password` in the JSON:** Fedora 44
ships systemd 259. systemd-homed 259 does NOT auto-process the
`secret` section of an identity passed via `--identity=` — that
landed in systemd 260+. On F44 the only path that actually seeds the
LUKS keyslot is `homectl`'s `PASSWORD`/`NEWPASSWORD` env vars. Once
F45 ships systemd 260+, `secret.password` in the identity file
becomes viable and the env-var path can retire.

**Adding a user:** drop `/usr/share/myosi/users/<name>.user` into
`mkosi.extra/` and add `enable myosi-homed-user@<name>.service` to
`50-myosi.preset`. No script edits.

**Storage backend:** `luks` (per-user LUKS2 image with btrfs inside,
20 GiB default). Defence in depth on top of data-luks: data-luks
protects the disk at rest; per-home LUKS protects one user's data
even against another user on the same booted system who gains root
and dumps `/var`. Trade-off accepted: first-boot `homectl create`
blocks 5-10 min on slow CPUs / emulated TPM during LUKS format.

```
/var/data-luks (LUKS + btrfs)
└── /home/
    └── user.home            ← LUKS image file (per-user encryption)
        └── (when activated → /home/user, inner btrfs)
```

**First-boot flow:**

1. `myosi-sshd-hostkeys.service` generates rsa+ecdsa+ed25519 host keys
   sequentially in `/etc/ssh/` (preserved from the overlay era as
   belt-and-suspenders; the /etc subvol is a plain filesystem so the
   parallel `sshd-keygen@*` race no longer applies, but the
   sequential generator costs nothing and keeps logs readable).
2. `systemd-homed.service` starts. `myosi-homed-user@user.service`
   runs `homed-user-provision user`, which calls `homectl
   create --identity=/usr/share/myosi/users/user.user
   --storage=luks ...` with the `changeme` bootstrap password via
   `PASSWORD`/`NEWPASSWORD` env vars.
3. Operator SSHes in as root via fleet-keys → either logs in directly
   as user (also via fleet-keys, no password needed) or runs
   `homectl passwd user` to rotate the bootstrap password.
4. (Optional) Operator runs `sudo loginctl enable-linger user`
   if they want rootless quadlets to keep running across reboots.
   Linger is NOT enabled by default — at every boot it tries to
   activate the homed home, which fails unattended (LUKS needs the
   passphrase) until TPM2 enrolment.

**Post-install root access (fresh image state):**

| Path | State on fresh install | Notes |
|------|------------------------|-------|
| `/etc/shadow` `root` | locked (`!locked`) — no password | Console login as root refused until operator sets one |
| `/etc/ssh/sshd_config.d/50-myosi.conf` | `PermitRootLogin prohibit-password` | Root SSH allowed via publickey only — no password method |
| baked authorized_keys | typically provisioned for `user`, not `root` | Root SSH won't work in prod until a root key is shipped (overlay, `/etc` drop-in, or credential) |
| `user` | created by homed (subvol), `changeme` password, all fleet keys | Default login path on every host |

So out of the box, only **user** can log in (SSH publickey via
fleet-keys, OR console with `changeme`). `sudo` works from there.

**Upgrading user's home to LUKS + TPM2 (single-host, console-driven):**

This is the in-place upgrade flow that works on a fresh install with
nothing but local console access. `homectl deactivate` refuses while
any user session is live, so we route the upgrade through a root
TTY session that owns no user state.

```bash
# Step 1 — from any user session (SSH or console), give root a
# password so we can switch to a root TTY shortly. sudo asks for
# user's password (changeme on first boot).
sudo passwd root

# Step 2 — log user out completely.
exit                                       # leave the SSH session, or
loginctl terminate-user user          # if you're at the console
# At the console: Ctrl-Alt-F2 → fresh login prompt.

# Step 3 — log in as root on a TTY console (tty1/ttyS0) with the
# password you just set. Root TTY login is allowed by default.
# Now run the upgrade from a root scope:
loginctl disable-linger user          # stop user@1000.service from auto-restart
systemctl stop user@1000.service           # ensure manager exits
homectl deactivate user               # unmount the subvol

homectl update user \
    --storage=luks \
    --disk-size=20G \
    --fs-type=btrfs                        # converts subvol → LUKS image, copies data in
# Optional: TPM2 auto-unlock at boot
homectl update user \
    --tpm2-device=auto \
    --tpm2-pcrs=7+14 \
    --auto-login=yes

loginctl enable-linger user
PASSWORD=changeme homectl activate user  # use the current user password

# Step 4 (optional, recommended) — re-lock root so password login goes
# back off. Root SSH-as-key still works if you've added a fleet-keys
# entry for root.
passwd -l root
```

Reversible — `homectl update user --storage=subvolume` shrinks back
out to a plain subvol (same deactivate-first requirement).

**Alternative: two-host upgrade (preferred if you have a second box):**

Faster, doesn't need a console. Requires root SSH access: ship a root
key at `/etc/ssh/authorized_keys.d/root`, via the
`ssh.authorized_keys.root` systemd credential, or in a private
`usr/share/myosi/ssh/authorized_keys.d/root` overlay.

```bash
# from a laptop with one of the root fleet keys:
ssh -i ~/.ssh/myfleetkey root@host

# on the host (root scope, no user session involved):
loginctl terminate-user user
loginctl disable-linger user
systemctl stop user@1000.service
homectl deactivate user
homectl update user --storage=luks --disk-size=20G --fs-type=btrfs
homectl update user --tpm2-device=auto --tpm2-pcrs=7+14 --auto-login=yes
loginctl enable-linger user
PASSWORD=changeme homectl activate user
```

**Day-to-day operations:**

```bash
homectl list                              # all managed users + activation state
homectl inspect user                 # full record + disk usage
homectl passwd user                  # rotate password (re-keys LUKS slot)
homectl update user --disk-size=50G  # grow LUKS home (online)
homectl activate user                # manually mount home
homectl deactivate user              # unmount + lock (LUKS backend)
homectl lock user                    # lock without unmount (suspend)
homectl unlock user                  # unlock after suspend
```

**Recovery / drift / re-enrollment (LUKS backend only):**

```bash
# TPM2 PCR changed (firmware update, secureboot key swap) → auto-unlock fails.
# SSH in (key auth works via fleet-keys), PAM falls back to passphrase
# prompt on PTY, type passphrase, then:
homectl update user --tpm2-device=auto --tpm2-pcrs=7+14

# Generate a one-time recovery key (print and store offline):
homectl update user --recovery-key
# Use it later to reset a forgotten passphrase.
```

**Snapshots and backups:**

```bash
# Operator-level whole-/home snapshot (captures all .home files atomically):
sudo btrfs subvolume snapshot /home /home/.snapshots/$(date -u +%Y-%m-%dT%H%M%S)

# Per-user snapshot inside LUKS home (user logged in):
btrfs subvolume snapshot ~ ~/.snapshots/before-experiment

# Backup a single user (LUKS backend, user logged out):
sudo cp --reflink=auto /home/user.home /backup/user-$(date +%F).home

# Restore on a new host:
sudo cp --reflink=auto /backup/user-2026-06-13.home /home/user.home
```

**Adding a new user (declarative):**

1. Generate a SHA-512 hash for the default password:
   ```bash
   openssl passwd -6 -salt $(openssl rand -hex 8) MyDefault123
   ```
2. Ship a new record at `mkosi.extra/usr/share/myosi/users/<name>.user`
   mirroring the user record's shape (`userName`, `uid`, `gid`,
   `realName`, `homeDirectory`, `shell`, `memberOf`,
   `privileged.hashedPassword`, `privileged.sshAuthorizedKeys`,
   `storage`). NOT `/usr/lib/userdb/` — homed refuses to create a user
   already visible to NSS as a static record.
3. If the user needs groups not yet in
   `mkosi.extra/usr/lib/sysusers.d/myosi-groups.conf`, add them there.
   Do NOT pre-declare the user's primary group — homed owns it.
4. Extend `firstboot-homed` to materialize the new user (currently
   hardcodes user; future iteration could loop over all
   `/usr/share/myosi/users/*.user`).
5. Rebuild + redeploy.

**Old hardware (pre-AES-NI):** the subvolume backend skips nested LUKS,
so there's no nested-crypto overhead. CPUs without AES-NI (Intel
pre-Westmere 2010, AMD pre-Bulldozer 2011) take a 50%+ throughput hit
with LUKS-backed homes — the auto-probe picks subvolume when no TPM2 is
present, which is the typical correlate.

#### 3a.2. Steam library and Flatpak conventions

Two paths kept out of /home so homed-managed homes stay lean:

- **Steam library** lives at `/var/games/steam` (pre-created by
  `tmpfiles.d/myosi.conf`, owned by `user`). In Steam: Settings →
  Storage → Add Library Folder → `/var/games/steam`, mark as default
  for new installs. Game configs and save data stay in
  `~/.steam/steam/userdata/` (small).
- **Flatpak** installs go to `/var/lib/flatpak` system-wide by default
  (no `--user`). Shared across users. Per-app data lives in
  `~/.var/app/<app>/` (small).

Why outside /home: game binaries are public — no need for per-user
crypto on top of data-luks. Per-user LUKS homes default to 20 GiB which
Steam would blow past instantly; resize is easy (`homectl update
user --disk-size=200G`) but the out-of-home path is the cleaner
model.

#### 3b. Disk fills itself automatically on first boot

No manual resize step is needed. The initrd boot chain handles disk growth end-to-end:

1. `systemd-repart.service` runs after `sysroot.mount`, reads `/usr/lib/repart.d/*.conf` from the initrd, creates the `data-luks` partition (or grows it to fill the disk on subsequent boots), formats it as LUKS2 + btrfs, and creates `/var`, `/etc`, `/home`, and `/srv` subvolumes.
2. `myosi-data-attach.service` unlocks `/dev/mapper/data` and any present `data-N` pool members, runs `btrfs device scan`, and prepares the `/etc` subvol (seed + label). `sysroot-etc.mount` mounts `/etc` before pivot; `var.mount` is gpt-auto-generated post-pivot. btrfs sees the full grown mapper size immediately.
3. Re-partition and growth on subsequent boots is automatic: repart grows the GPT partition before unlock, the mapper opens at the current partition size, and filesystem growth stays in the repart/grow path — not in `myosi-data-attach`.

Sanity-check after the first boot if you like:

```bash
df -h /var /home                                    # full disk capacity
sudo cryptsetup status var                          # LUKS device size = partition size
sudo gdisk -l /dev/disk/by-id/<your-nvme-id>        # no "Alt. header" warning
sudo btrfs filesystem show /var                     # btrfs span = LUKS payload
```

If you re-image the disk onto a larger drive, repart will grow the partition layout to fill the new free space on the next boot — no operator action needed.

#### 3c. Enroll signing certificates for Secure Boot, verity and sysexts

myosi uses two certificates:

| Cert | Purpose | Needed for |
|------|---------|------------|
| `boot.der` | boot chain trust | systemd-boot, UKI, signed kernel modules |
| `image.der` | image trust | dm-verity root hash, sysexts |

The files are available in two places:

```text
/efi/keys/boot.der       # vfat ESP copy, easiest for firmware setup UI
/efi/keys/image.der
/usr/share/myosi/keys/boot.der
/usr/share/myosi/keys/image.der
```

Preferred hardware path: enroll both certs into firmware **db**. Reboot into firmware setup, then use the Secure Boot key management UI:

```text
Secure Boot → Key Management → Authorized Signatures (db) → Append Key
```

Select the ESP volume and enroll:

1. `/keys/boot.der` as **Public Key Certificate**
2. `/keys/image.der` as **Public Key Certificate**

Do not replace `PK` or `KEK`; append to `db` only. Keep vendor/Microsoft keys unless you intentionally want a custom-only Secure Boot policy.

Alternative path: enroll through MOK when the machine boots through shim:

```bash
sudo mokutil --import /usr/share/myosi/keys/boot.der
sudo mokutil --import /usr/share/myosi/keys/image.der
sudo reboot
```

At MokManager, choose **Enroll MOK**, enter the temporary password, and reboot again. MOK is useful when firmware UI is painful. Firmware db enrollment is cleaner because the kernel loads db certificates into `.platform` directly. Either way, verify after boot:

```bash
sudo mokutil --sb-state
sudo keyctl list %:.platform
sudo keyctl list %:.machine
sudo dmesg | grep -iE 'verity|enokey' || true
```

Expected: `myosi DEV Boot` and `myosi DEV Image` appear in a trusted kernel keyring, and there are no `ENOKEY` verity errors when sysexts merge.

Secure Boot can be disabled and the base image will still boot, but signed verity/sysext validation still needs `image.der` available to the kernel. If sysext merge logs `key is not available`, enroll `image.der` through firmware db or MOK.

#### 3d. data-luks keyslot management

**On first boot, `systemd-repart` formats `data-luks` with a bootstrap key from the UKI (slot 0).** The key was generated at build time by `scripts/generate-bootstrap-key.sh` and embedded in the verity-baked root at `/usr/share/myosi/keys/data.key`. The initrd `myosi-data-attach` service probes this key first before falling through to TPM2/passphrase, so boot is non-interactive on systems with or without TPM2.

**THIS IS WHY THE FOLLOW-UP STEP IS MANDATORY.** Anyone with physical access to the unencrypted ESP can extract the UKI, pull the key out, and unlock the disk. The build-time key is the active unlock token until you replace it.

Architecture chosen because:
- Universal: same image works on TPM2 hardware, no-TPM hardware (old machines, VMs without swtpm, servers with TPM disabled in BIOS).
- No boot hangs: first boot uses the key file, subsequent boots use the key file too (until wiped) so the host never gets stuck at an unlock prompt during install.
- Operator chooses when to finalise: enroll TPM2 (if available) and/or a passphrase, then wipe the bootstrap slot. After that, the embedded key matches no slot and is dead weight in the UKI.

To finalise the install you typically:
1. Enroll a real auth method (TPM2 if the host has one, passphrase otherwise).
2. Wipe the build-time bootstrap key slot.

Both must happen for the host to be considered installed. Until they do, treat the disk as if it weren't encrypted.

Reference for crypttab / luks tooling: `systemd-cryptenroll(1)`, `cryptsetup(8)`, `crypttab(5)`.

**Pick the device path once** (LUKS UUID is most stable):

```bash
DEV=/dev/disk/by-partlabel/data-luks
```

**List currently enrolled methods:**

```bash
sudo systemd-cryptenroll "$DEV"
# Fresh install: slot 0 is the bootstrap key-file slot created by repart.
sudo cryptsetup luksDump "$DEV" | grep -E 'Keyslots:|Tokens:|^  [0-9]+:'
```

**Add an operator passphrase** (authorize with the embedded bootstrap key file; this is the universal path on TPM and non-TPM hosts):

```bash
sudo cryptsetup luksAddKey --key-file /usr/share/myosi/keys/data.key "$DEV"
# Enter the new operator passphrase twice.
sudo systemd-cryptenroll "$DEV"
# Expect at least one operator-controlled password slot in addition to slot 0.
```

**Optional: add TPM2 auto-unlock** (authorize with the passphrase you just added, bind to PCR 7+14):

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 "$DEV"
sudo systemd-cryptenroll "$DEV"
# Expect both `password` and `tpm2` listed.
```

**Finalize: wipe the bootstrap key-file slot** (mandatory before treating the disk as encrypted):

```bash
# Repart creates the bootstrap key in slot 0. Do this only after adding
# a passphrase, TPM2 token, or recovery key you have verified.
sudo cryptsetup luksKillSlot "$DEV" 0

# Verify the embedded key is dead. This command should FAIL.
sudo cryptsetup luksOpen --test-passphrase \
    --key-file /usr/share/myosi/keys/data.key "$DEV" \
    && echo "ERROR: bootstrap key still unlocks" \
    || echo "ok: bootstrap key no longer unlocks"

sudo systemd-cryptenroll "$DEV"
sudo reboot
```

**Switch to passphrase-only boot** (wipe TPM2 keyslot, if you enrolled one):

```bash
sudo systemd-cryptenroll --wipe-slot=tpm2 "$DEV"
# Verify: only `password` remains.
sudo systemd-cryptenroll "$DEV"
sudo reboot
# Next boot prompts for the passphrase on the console.
```

**Re-enroll TPM2 after a firmware / SecureBoot / MOK change** (you must already have a passphrase keyslot or recovery key — cryptenroll requires an existing unlock method):

```bash
sudo systemd-cryptenroll --wipe-slot=tpm2 \
    --tpm2-device=auto --tpm2-pcrs=7+14 "$DEV"
# Prompts for the existing passphrase, then enrolls the new TPM2 slot.
sudo reboot
```

**Generate a one-time recovery key** (single-use printable, store offline; useful when both TPM2 and your passphrase have failed):

```bash
sudo systemd-cryptenroll --recovery-key "$DEV"
# Print the displayed key and store it in a safe. Won't be shown again.
```

**Remove a slot you no longer want** (passphrase or recovery):

```bash
sudo systemd-cryptenroll --wipe-slot=password "$DEV"
sudo systemd-cryptenroll --wipe-slot=recovery "$DEV"
```

**Safety**: NEVER wipe the last unlock method. cryptsetup does not prevent this — verify after every wipe with `systemd-cryptenroll "$DEV"` that at least one of `tpm2`, `password`, or `recovery` remains. Otherwise the disk is unrecoverable on next boot.

> The `tpm2-device=auto` fallback in `myosi-data-attach`'s `unlock_one` function is harmless when no TPM2 token is enrolled: `systemd-cryptsetup attach` tries TPM2, finds no token, and falls through to the passphrase prompt on the console. No config edit required after `--wipe-slot=tpm2`.

#### 3e. Enable sysext features

Sysexts are signed `.raw` images that merge into `/usr`. Each optional feature is disabled until the host opts in. The helper writes the feature drop-in, downloads only the requested private GitHub release asset, installs it in `/var/lib/extensions`, and refreshes the sysext overlay. With no explicit version, it installs the sysext matching the running host's `IMAGE_VERSION`.

First authenticate GitHub CLI once:

```bash
gh auth login
gh auth status
```

Then enable the features this host needs:

```bash
sudo myosi extension-enable containers     # podman, distrobox, skopeo, incus
sudo myosi extension-enable virt           # libvirt, qemu, vfio, virt-manager
sudo myosi extension-enable desktop        # niri, terminals, waybar, pipewire, fonts, mesa
sudo myosi extension-enable zfs            # OpenZFS module + userspace
```

NVIDIA hosts must pick exactly one branch:

```bash
sudo myosi extension-enable nvidia         # Turing+ / RTX generations, open kmod
sudo myosi extension-enable nvidia-580xx   # Maxwell/Pascal/Volta legacy branch
```

Disable a feature:

```bash
sudo myosi extension-disable <name>
sudo reboot
```

Inspect extension state:

```bash
sudo myosi extension-list
sudo systemd-sysext list
```

#### 3f. Update base system and sysexts

Updates are cache-first because the source repository is private. `updatectl` installs from local files in `/var/lib/sysupdate`; `myosi update` fetches those files from GitHub with authenticated `gh`.

Recommended all-in-one update:

```bash
sudo myosi update
sudo reboot
```

That resolves the latest GitHub release once, downloads that exact version, then applies that same version to:

```text
host                  # A/B root + verity + UKI
component:extensions  # enabled sysext features (includes fleet-keys)
```

Split fetch/apply flow:

```bash
sudo myosi fetch          # latest release
sudo myosi apply          # latest cached candidate

sudo myosi fetch 2026.06.04.01
sudo myosi apply 2026.06.04.01
```

`fetch`, `apply`, and `update` stage updates only. They do not refresh the running sysext layer. Reboot is the normal activation path and keeps the root image, UKI, and sysexts in one matching generation.

If you intentionally want live extension activation without rebooting, use the explicit refresh mode:

```bash
sudo myosi apply 2026.06.04.01 true
sudo myosi update --refresh
```

That runs `systemd-sysext refresh` after `updatectl` applies the cached artifacts. It does not restart arbitrary services; restart affected daemons manually. Prefer reboot for root-coupled or kernel-module sysexts such as NVIDIA and ZFS.

Manual equivalent:

```bash
sudo systemd-sysext refresh
```

Inspect or clean old generations:

```bash
sudo myosi status
sudo myosi vacuum
```

The base update writes the inactive A/B slot and the new UKI. The current root remains unchanged until reboot even when `--refresh` is used. sd-boot boot counting tries the new entry and rolls back if it fails repeatedly.

The transfer definitions live in:

```text
/usr/lib/sysupdate.d/            # host root, verity, verity signature, UKI
/usr/lib/sysupdate.extensions.d/ # sysext features (incl. fleet-keys)
```

All of them read from:

```text
/var/lib/sysupdate
```

#### 3h. Manual sysext install without `extension-enable`

Use this only for debugging or one-off installs. The normal path is `extension-enable`.

```bash
gh auth login
VERSION="$(gh release view --repo user/myosi --json tagName --jq .tagName)"
EXT=containers
mkdir -p /tmp/myosi-ext

gh release download "$VERSION" \
  --repo user/myosi \
  --pattern "${EXT}_${VERSION}.raw" \
  --dir /tmp/myosi-ext \
  --clobber

sudo mkdir -p /var/lib/extensions
sudo install -m 0644 \
  "/tmp/myosi-ext/${EXT}_${VERSION}.raw" \
  "/var/lib/extensions/${EXT}_${VERSION}.raw"

sudo systemctl enable systemd-sysext.service
sudo systemctl restart systemd-sysext.service || sudo reboot
systemd-sysext list
```

To make sysupdate keep that sysext updated later, enable the feature gate too:

```bash
sudo mkdir -p "/etc/sysupdate.extensions.d/${EXT}.feature.d"
printf '[Feature]\nEnabled=true\n' | \
  sudo tee "/etc/sysupdate.extensions.d/${EXT}.feature.d/enable.conf"

sudo myosi update
```

#### 3i. Encrypted btrfs data pool — inspect and extend

`/var` and `/home` are the two top-level subvolumes of the same encrypted btrfs filesystem on `data-luks`. Nested paths (`/var/tmp`, `/var/cache`, `/var/log`, `/var/lib/containers`, `/var/lib/libvirt`, `/var/lib/incus`) live as regular dirs inside the `/var` subvolume (no per-path subvol mount).

Reference: `btrfs(8)`, `cryptsetup(8)`, `crypttab(5)`.

**Inspect the current pool:**

```bash
sudo btrfs filesystem show /var
sudo btrfs filesystem usage /var
sudo btrfs subvolume list /var
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL,UUID
```

**Secondary LUKS devices are discovered dynamically by the initrd helper.**

The primary `data-luks` partition is not selected globally by label. In the initrd, `myosi-data-attach.service` runs `/usr/libexec/myosi/data-attach`, which:

1. Finds `/sysroot`'s mount source, walks dm-verity slaves to the real root GPT partition, resolves the parent disk, and selects exactly one DPS `Type=var` partition on that same disk (**guard rail: primary `/var` must come from the boot disk**).
2. Unlocks it as `/dev/mapper/data` — tries the embedded key-file first (`/usr/share/myosi/keys/data.key`), falls through to `systemd-cryptsetup attach ... tpm2-device=auto,discard` for TPM2/passphrase.
3. Scans **every** disk for LUKS containers with `data-[0-9]+` labels and unlocks them as pool members (multi-disk hosts: secondary disks contribute their `data-N` containers regardless of which disk they sit on).
4. Runs `btrfs device scan` so the kernel knows about every multi-device pool member.
5. Mounts the btrfs top-level briefly to prepare the `/etc` subvol: verify it exists (fail loudly if not — upgrade hosts must create it manually per the upgrade runbook), seed it from `/sysroot/usr/share/factory/etc` if empty, `setfattr etc_t` on its root inode.

`sysroot-etc.mount` then mounts `/dev/mapper/data` with `subvol=/etc` at `/sysroot/etc` before pivot. `/var` is NOT mounted in the initrd — `systemd-gpt-auto-generator` auto-emits `var.mount` post-pivot from the DPS `Type=var` partition + `DefaultSubvolume=/var`, same lifecycle as `home.mount` and `srv.mount`.

There is no sealed-root `/etc/crypttab`, no pre-declared slot list, and no runtime udev/template service for `data-N`. Any `data-N` device that gates `/var` must be present during initrd boot so `myosi-data-attach` can unlock it before the btrfs mount. Post-switch hotplug of unrelated encrypted disks belongs in operator-managed `/etc/crypttab` (persistent on the `/etc` subvol) or explicit units, because those disks do not gate the `/var` or `/etc` subvolumes that the boot path requires.

**Critical systemd behaviour notes that drove this design:**
- `systemd-gpt-auto-generator` does not mount non-root DPS `Type=var` partitions in the initrd; it handles `/var` after `switch_root`.
- myosi needs `/sysroot/var` AND `/sysroot/etc` before `switch_root` because both live as sibling subvolumes on the same `data-luks` btrfs volume.
- Global `PARTLABEL=data-luks` selection is unsafe when another myosi disk is attached. The initrd helper scopes primary `/var` selection to the same disk as the booted root.
- Pool members (`data-N`) are intentionally NOT scoped to the boot disk — multi-disk hosts keep their secondary LUKS containers on dedicated disks, and the scanner must find them across all available block devices.
- Pre-declared crypttab slots (`data-1..data-N nofail`) work but cap N and clutter the running system with pending jobs for unused slots.
- A runtime udev/template unlock path was tested and removed. It added a second automatic unlock path with ordering/escaping edge cases, while `myosi-data-attach` already must scan and unlock the complete btrfs pool before the `/sysroot/{var,etc}.mount` units fire.

**Label-namespace invariant:** `myosi-data-attach` scans LUKS container labels with `blkid -s LABEL` before unlocking. Reserve `data-[0-9]+` labels for LUKS containers that are actual members of the `/var` btrfs pool. Do not use that label pattern for unrelated encrypted disks, because present matching devices are treated as mandatory boot-time pool members.

**Add a second full-disk LUKS device to the `/var` btrfs pool:**

```bash
# Pick by-id for stability across reboots
DISK=/dev/disk/by-id/nvme-MODEL_SERIAL

# Wipe any existing FS signatures
sudo wipefs -a "$DISK"

# luksFormat. The --label MUST match the data-<digit>+ pattern that
# myosi-data-attach scans for in the initrd; data-1, data-2, etc. `--force-password`
# bypasses the libpwquality dictionary check (cracklib-dicts is not
# in the base image). Type the new passphrase twice when prompted.
sudo cryptsetup luksFormat --type luks2 --label data-1 --force-password "$DISK"

# Open and map (use the same name as the LUKS label so the mapper
# name matches the next boot's myosi-data-attach mapping).
sudo cryptsetup luksOpen "$DISK" data-1

# MANDATORY: enroll a TPM2 keyslot so the disk unlocks silently on
# every boot. Without this, cryptsetup at boot falls through to the
# console passphrase prompt; on an unattended boot or a headless
# server it just hangs (no operator at the console to type).
# Bind to PCR 7+14 — same policy as the primary, stable across UKI
# updates.
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 "$DISK"

# Add to the btrfs pool
sudo btrfs device add /dev/mapper/data-1 /var

# Convert to keep data single (full capacity, no redundancy)
# and mirror metadata + system across both disks
sudo btrfs balance start -dconvert=single -mconvert=raid1 -sconvert=raid1 /var
sudo btrfs balance status /var

# Verify
sudo btrfs filesystem show /var
sudo btrfs filesystem usage /var | head -25
df -h /var
sudo reboot     # confirm everything comes up cleanly
```

On reboot, both disks unlock silently via TPM2 (no passphrase prompt). btrfs assembles the multi-device pool, `/var` mounts.

**If you skipped the TPM2 enrollment**, every boot prompts for `data-1`'s passphrase on the console after primary's TPM unlock. Fine on a workstation; broken for headless / unattended setups. Always enroll.

**Need more secondary disks?** Use the next `data-N` LUKS label; there is no fixed slot cap. For LUKS volumes that don't gate `/var` itself — external archives mounted after multi-user.target, opt-in encrypted home subvols — operators can edit `/etc/crypttab` post-boot (persistent on the `/etc` btrfs subvol); those entries don't need to exist in the initrd because they aren't required during the boot path that builds `/var` and `/etc`.

**Create a separate encrypted btrfs pool** (e.g. for archive storage at `/mnt/data`):

```bash
# Encrypt each device
for D in /dev/disk/by-id/nvme-X /dev/disk/by-id/nvme-Y; do
    L=$(basename "$D")
    sudo wipefs -a "$D"
    sudo cryptsetup luksFormat --type luks2 --label "pool-$L" --force-password "$D"
    sudo cryptsetup luksOpen "$D" "pool-$L"
    echo "pool-$L  UUID=$(sudo cryptsetup luksUUID $D)  none  discard" | \
        sudo tee -a /etc/crypttab
done

# Format btrfs across the mapper devices with whatever profile you want
sudo mkfs.btrfs -L pool -d raid1 -m raid1 /dev/mapper/pool-*

# Mount
sudo mkdir -p /mnt/data
UUID=$(sudo blkid -s UUID -o value /dev/mapper/pool-* | head -1)
echo "UUID=$UUID  /mnt/data  btrfs  defaults,noatime,compress=zstd:3  0 0" | \
    sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount /mnt/data
```

**Btrfs profile cheat sheet:**

| Profile | Min devices | Redundancy | Use |
|---------|-------------|------------|-----|
| `single` | 1 | none | max capacity, backup required |
| `raid0` | 2 | none | striped, no redundancy |
| `raid1` | 2 | one mirror | default safe multi-disk |
| `raid10` | 4 | mirrored stripes | 4+ disk VM/storage host |
| `raid1c3` | 3 | three copies | high redundancy |
| `raid1c4` | 4 | four copies | high redundancy |

Convert profiles in-place with `btrfs balance start -dconvert=PROFILE -mconvert=PROFILE /var` (data + metadata) or use separate `-d` / `-m` / `-s` if you want different profiles for each chunk class.

**Operator rules:**

- Always keep backups. btrfs redundancy is availability, not backup.
- Do NOT add USB / removable disks to `/var` — boot depends on every crypttab device unlocking.
- Prefer `raid1` for persistent data on two or more disks.
- Periodic scrub on redundant pools:

```bash
sudo btrfs scrub start -Bd /var
sudo btrfs scrub status /var
```

#### 3j. Virt host integration, if the `virt` sysext is enabled

Skip if you did not enable `virt`. The base image ships no libvirt
configs — they live in a single setup script under the virt sysext
itself. Running it once provisions:

- A host NetworkManager bridge `br0`, enslaving your default-route
  physical iface so VMs attached to it get LAN IPs from your router.
- libvirt networks `default` (NAT virbr0 — uses the upstream
  `/usr/share/libvirt/networks/default.xml` template) and `br0`
  (`<forward mode='bridge'/>` pointing at the host bridge).
- libvirt storage pools `default` (`/var/lib/libvirt/images`, qemu:qemu,
  NoCOW btrfs subvol, `virt_image_t`) and `isos`
  (`/var/lib/libvirt/isos`, `virt_content_t`).

```bash
# From the local console (recommended — the bridge step briefly takes
# the physical iface offline; SSH will see a 5-30 s gap):
sudo /usr/libexec/myosi/virt-setup

# If the auto-detected iface is wrong:
sudo /usr/libexec/myosi/virt-setup --bridge-iface=enp3s0

# Skip the bridge (only configure libvirt networks + pools):
sudo /usr/libexec/myosi/virt-setup --skip-bridge

# Bridge only, no libvirt yet:
sudo /usr/libexec/myosi/virt-setup --bridge-only
```

Idempotent — re-runs check every step and skip what's already in
place, so it is safe to run after partial failures.

Two libvirt networks ship from the script:

| Network | Bridge | Mode | Use |
|---------|--------|------|-----|
| `br0` | `br0` | LAN bridge | guests get LAN addresses from the router |
| `default` | `virbr0` | NAT | isolated guests with outbound internet |

VM disks live under `/var/lib/libvirt/images`; ISOs under `/var/lib/libvirt/isos`. The upstream-canonical libvirt paths line up with stock SELinux policy — no aliases or local rules needed.

Remote virt-manager:

```bash
virt-manager -c qemu+ssh://user@<host>/system
```

### Useful diagnostics on a deployed host

```bash
# Boot chain + bootloader state
sudo bootctl status
sudo efibootmgr -v
ls /efi/EFI/BOOT/ /efi/EFI/Linux/

# Kernel keyrings
sudo keyctl list %:.platform
sudo keyctl list %:.machine

# Verity + sysext state
sudo veritysetup status root
sudo systemd-sysext status
sudo systemd-dissect /var/lib/extensions/<name>_<VER>_<ARCH>.raw

# Disk + LUKS + btrfs
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL
sudo cryptsetup status var
sudo btrfs filesystem usage /var
sudo btrfs subvolume list /var

# Update state
sudo myosi update status

# Signature validation failures
sudo dmesg | grep -iE 'verity|enokey' || true
```

---

## Upgrading an existing host to the /etc-subvol model (one-time)

Existing hosts have a `data-luks` btrfs formatted under the old overlay model: `/var`, `/home`, `/srv` subvolumes exist; `/etc` does NOT exist as a subvolume; operator-written `/etc` state lives in the overlay upperdir at `/var/etc/`. `systemd-repart`'s `Subvolumes=/etc` only fires at format time, so the new image will NOT auto-create the subvol — the initrd drops to emergency with `data-attach: /etc subvol missing on /dev/mapper/data`.

There is no in-image migration shim. From the booted old image (overlay still active), one command and a reboot:

```bash
sudo mount -t btrfs -o subvol=/,noatime /dev/mapper/data /mnt
sudo btrfs subvolume create /mnt/etc
sudo umount /mnt
sudo reboot
```

`subvol=/` mounts the btrfs top-level (sibling space for `/var`, `/etc`, `/home`, `/srv`). `subvolid=5` is the numeric equivalent. The running `/var` mount only exposes the `/var` subvolume's contents — sibling subvolumes are invisible from there, so a separate top-level mount is unavoidable.

The new boot:

1. `myosi-data-attach` finds the now-existing `/etc` subvol, `setfattr`s `etc_t` on its root inode, and continues.
2. `sysroot-etc.mount` mounts the (empty) `/etc` subvol at `/sysroot/etc`.
3. `myosi-etc-seed.service` (initrd) runs `cp -a --reflink=auto /sysroot/usr/share/factory/etc/. /sysroot/etc/` and `setfattr etc_t /sysroot/etc` — `ConditionDirectoryNotEmpty=!/sysroot/etc` gates first-boot-only.
4. The system boots clean with factory defaults.

The old operator state still sits at `/var/etc/` as a plain directory inside the `/var` subvol (the overlay is gone — it's just a regular tree now). Restore your customizations selectively:

```bash
# Spot-check what was operator-modified:
sudo diff -ruN /etc /var/etc | less

# Copy specific files back as needed, e.g.:
sudo cp -a /var/etc/hostname /etc/hostname
sudo cp -a /var/etc/NetworkManager /etc/
sudo cp -a /var/etc/ssh/ssh_host_* /etc/ssh/
# … etc, whatever you actually customised

# When done, reclaim the space:
sudo rm -rf /var/etc /var/.etc-work
sudo restorecon -RF /etc        # belt-and-suspenders SELinux re-label
```

If the new boot fails for any reason, the OLD image is still bootable from the inactive A/B slot: at the sd-boot menu press Space and select the previous UKI. The old image's initrd ignores the new `/etc` subvol entirely.

**Fresh installs need none of this** — `systemd-repart` runs at format time, `Subvolumes=/etc` in `90-data.conf` creates the subvol, `myosi-etc-seed.service` (initrd) copies `/sysroot/usr/share/factory/etc/.` into the empty subvol on first boot.

---

## Reconciling `/etc` with the factory `/usr/share/factory/etc`

After the first boot, **the operator owns `/etc`** — bootc / ostree / Fedora Atomic semantics. The initrd `myosi-etc-seed.service` only fires on a fully empty `/etc` subvol (`ConditionDirectoryNotEmpty=!/sysroot/etc`). On every subsequent boot the unit is skipped, so:

- Files the operator modified persist untouched across image upgrades.
- New files added to `/usr/share/factory/etc/` in a later image are **NOT** auto-copied into `/etc`.
- Files removed from `/usr/share/factory/etc/` in a later image leave a stale copy in `/etc/`.

Reconciliation is manual + selective. The pattern is: **inspect the diff, copy what matters, leave the rest.**

### Inspect the drift

The factory tree on the running host is at `/usr/share/factory/etc/` (verity-baked, swaps atomically with each image upgrade). The live tree is at `/etc/` (persistent subvol on `data-luks`). Three commands, increasing detail:

```bash
# 1. What paths differ at all? Summary only, no content.
diff -rq /usr/share/factory/etc /etc | sort | less

# 2. Per-file stat (lines added/removed). Modern, colorized.
git diff --no-index --stat /usr/share/factory/etc /etc | less

# 3. Full unified diff with colors. Pipe to delta if installed.
git diff --no-index /usr/share/factory/etc /etc | less -R
git diff --no-index /usr/share/factory/etc /etc | delta            # alt
```

`git diff --no-index` works on any two paths, no repo needed. If you have `delta` configured as `core.pager`, the output is colorized + side-by-side. Without it, `less -R` honors the ANSI colors git emits.

For just paths-that-differ without content:

```bash
diff -rq /usr/share/factory/etc /etc | awk '
    /^Only in \/usr\/etc/ { print "FACTORY-ONLY:", $0 }
    /^Only in \/etc/      { print "OPERATOR-ONLY:", $0 }
    /differ$/             { print "MODIFIED:    ", $3 }
'
```

For a file-list-only comparison (ignore content):

```bash
comm -23 <(cd /usr/share/factory/etc && find . | sort) <(cd /etc && find . | sort)   # factory-only
comm -13 <(cd /usr/share/factory/etc && find . | sort) <(cd /etc && find . | sort)   # operator-only
comm -12 <(cd /usr/share/factory/etc && find . | sort) <(cd /etc && find . | sort)   # in both
```

### Apply selectively

```bash
# Pull in a new factory default (operator decides per file):
sudo cp -a /usr/share/factory/etc/<path> /etc/<path>

# Restore a specific factory default after a bad operator edit:
sudo cp -a /usr/share/factory/etc/<file> /etc/<file>

# Reset a subtree:
sudo rm -rf /etc/<subdir>
sudo cp -a /usr/share/factory/etc/<subdir> /etc/<subdir>

# After bulk changes:
sudo restorecon -RF /etc      # belt-and-suspenders SELinux re-label
sudo systemctl daemon-reload  # if you touched unit-related dirs
```

Conventions:
- Use `cp -a` (preserve mode/owner/timestamps/xattrs including SELinux labels). `cp -p` skips xattrs and breaks SELinux.
- Use `--reflink=auto` if you want btrfs to share the underlying blocks with the source (cheap on btrfs; falls through to a real copy on non-btrfs).
- Don't use `rsync --delete` to "sync" `/etc` from `/usr/share/factory/etc` — it would erase operator state. The point of the subvol model is that `/etc` is yours.

### When to do this

- After every image upgrade you care about. Default cadence: spot-check at every release window.
- Whenever a behavior changes unexpectedly post-upgrade — first place to look is whether `/usr/share/factory/etc/<thing>` changed but `/etc/<thing>` is still the old version.
- After enabling a sysext that ships `/usr/share/factory/etc/` entries (rare; most sysexts stay under `/usr/lib/` and `/usr/share/`).

Reusable aliases (drop into `~/.bashrc` or fish `config.fish` — NOT shipped in the image):

```bash
alias etcdiff='git diff --no-index /usr/share/factory/etc /etc'
alias etcstat='git diff --no-index --stat /usr/share/factory/etc /etc'
alias etconly='diff -rq /usr/share/factory/etc /etc | grep "^Only in" | sort'
```

---

## Updates (cache-first sysupdate)

The deployed update interface is:

```bash
sudo myosi update [VERSION]
sudo myosi update --refresh [VERSION]
```

No version means latest GitHub release. An explicit version pins the fetch and apply to that version. This is the supported path for base A/B updates, enabled and enabled sysexts.

By default, updates are staged only. Reboot activates the new root and sysexts together. `--refresh` is an explicit live-extension mode for `update`: it refreshes the active sysext overlays after staging, but it does not change the running root or restart affected services.

Under the hood:

1. `gh release view` resolves the version.
2. `gh release download` fetches artifacts into `/var/lib/sysupdate`.
3. `sha256sum -c SHA256SUMS --ignore-missing` catches incomplete downloads.
4. `updatectl update host@VERSION` writes the inactive A/B root slot + UKI.
5. `updatectl update component:extensions@VERSION` updates enabled sysexts (including fleet-keys).

Do not point transfer files directly at GitHub URLs; the repository is private and sysupdate has no GitHub authentication. GitHub CLI authentication is intentionally isolated to `myosi update`.

## Filesystem maintenance (LUKS + btrfs, two nesting levels)

myosi has **two layered LUKS+btrfs stacks**:

1. **Outer pool — `data-luks`.** One LUKS container per disk (`/dev/mapper/data` + optional `data-N`). Inside: a single multi-device btrfs holding `/var`, `/etc`, `/home`, `/srv` as top-level subvolumes.
2. **Inner pool — per-user homed home.** systemd-homed creates `/home/<user>.home`, a sparse file on the `/home` subvol. Inside that file: another LUKS2 container wrapping another btrfs (mounted at `/home/<user>` on session activation).

Maintenance touches both. **Order matters: inner first, then outer.** Defragmenting the inner btrfs first coalesces extents inside the LUKS image; the image's storage backing on the outer btrfs then gets a chance to be defragmented as one contiguous-ish file. Doing outer first reorders blocks that the inner layer will immediately re-fragment with its own writes.

### Operations

| Operation | What it does | Cost |
|---|---|---|
| `btrfs scrub` | Reads every block, verifies checksums, repairs from redundant copy if profile allows (`dup`, `raid1`, ...). Detects bitrot. | I/O-heavy. Throttle for online operation. |
| `btrfs balance` | Re-spreads data across devices / chunk profiles. Useful after adding/removing a device, or when many small chunks accumulate. | Heavy. Don't run unless symptomatic. |
| `btrfs filesystem defragment` | Coalesces extents on specific files/dirs. Helps random-write workloads (qcow2 images, sqlite, journal). `-r` recursive. `-c<algo>` re-compress. | Moderate. CoW gets undone on touched files — snapshots of the same content get diverged. |
| `fstrim` | TELL underlying storage which blocks are free (`discard` ioctl). Improves SSD wear + LUKS allocation efficiency. | Cheap. Safe to run weekly. |

### systemd timers (shipped enabled in the base)

```bash
# Confirm timer state
systemctl status fstrim.timer btrfs-scrub@-.timer btrfs-scrub@home.timer 2>/dev/null
```

- `fstrim.timer` — weekly default on Fedora. Discards on every mounted FS that supports it.
- `btrfs-scrub@<escaped-mountpoint>.timer` — monthly per-mountpoint scrub. Enable explicitly per subvolume you care about; the package ships templates, not instances. The instance name encodes the mountpoint via `systemd-escape`:

```bash
# /var
sudo systemctl enable --now btrfs-scrub@$(systemd-escape -p /var).timer
# /home
sudo systemctl enable --now btrfs-scrub@$(systemd-escape -p /home).timer
# /etc
sudo systemctl enable --now btrfs-scrub@$(systemd-escape -p /etc).timer
# Inside an activated homed home (per-user shell):
sudo systemctl enable --now btrfs-scrub@$(systemd-escape -p /home/user).timer
```

There is no `btrfs-balance@.timer` and no `btrfs-defragment@.timer` shipped by default — those are operator-judgment operations, not safe to schedule unattended.

### Manual maintenance — recommended cadence

**Weekly (timer):** `fstrim -av`. Already automated by `fstrim.timer`. Verify:

```bash
sudo journalctl -u fstrim.service --since "1 month ago"
```

**Monthly (timer):** `btrfs scrub`. Already automated for each mountpoint with an enabled timer. Verify:

```bash
sudo btrfs scrub status /var
sudo btrfs scrub status /home
sudo btrfs scrub status /etc
sudo btrfs scrub status /home/user   # inside an activated home
```

If scrub reports any uncorrectable errors, restore the affected files from backup and consider replacing the disk.

**Quarterly or on-demand:** defragment write-heavy paths. **Inner first, then outer.**

```bash
# 1) INNER: while the home is activated (user logged in OR `homectl activate`),
#    defrag the per-user btrfs. This coalesces extents inside the .home LUKS image.
sudo systemd-run --on-active=now --pipe \
    btrfs filesystem defragment -r -czstd /home/user

# 2) Cleanly close the homed home so the .home LUKS image is flushed.
homectl deactivate user

# 3) OUTER: defrag the host btrfs paths that are write-heavy AND
#    the now-flushed .home files. compress=zstd on outer collapses
#    the encrypted blob's storage (LUKS payload is random-looking so
#    zstd won't shrink the inner content, but the outer extent layout
#    benefits from defrag's coalescing).
sudo btrfs filesystem defragment -r -czstd /var/lib/containers
sudo btrfs filesystem defragment -r -czstd /var/lib/libvirt
sudo btrfs filesystem defragment -r -czstd /var/lib/incus
sudo btrfs filesystem defragment -r -czstd /var/log
sudo btrfs filesystem defragment -r /home/*.home   # the LUKS image files
```

**As-needed (rare):** balance. Symptoms = many partially-empty data/metadata chunks visible in `btrfs filesystem usage`:

```bash
sudo btrfs filesystem usage /var      # look at Data/Metadata allocation vs. used
sudo btrfs balance start -dusage=50 -musage=50 /var
sudo btrfs balance status /var
```

`-dusage=50` rebalances data chunks below 50 % usage. Conservative threshold. Don't run a full `btrfs balance start /var` unless you really need it — it rewrites every chunk.

### Caveats specific to this stack

- **Defrag breaks CoW shares.** If you defrag a file that has snapshots or reflink copies, the defragged copy diverges from the snapshot — disk usage can grow. Run defrag BEFORE creating long-lived snapshots, or skip defragmenting files with active snapshot trees.
- **Inner LUKS image is sparse.** Don't `cp` the `/home/*.home` file with a tool that doesn't preserve holes — it'll inflate to the full 50 GiB. Use `cp --sparse=always`, `rsync --sparse`, or `dd conv=sparse`.
- **fstrim depth.** `fstrim /home` discards free blocks on the OUTER btrfs only. Inside an activated home, run `fstrim /home/<user>` to discard at the inner-btrfs level — that releases blocks back to the LUKS image, which is then visible to the outer btrfs on next outer-level trim. Both layers benefit.

```bash
# Both-layer trim sequence:
sudo fstrim /home/user      # inner btrfs (homed home must be activated)
homectl deactivate user      # flush + close the LUKS image
sudo fstrim /var /etc /home /srv  # outer btrfs (covers everything on data-luks)
```

- **scrub vs. memory-mapped reads.** During an online scrub, processes can keep reading; throughput drops moderately. Avoid running scrub during latency-sensitive workloads (gaming, recording).
- **TPM2 auto-unlock + scrub.** Scrub touches the same disk that holds the auto-unlock LUKS keyslot. No conflict — scrub reads encrypted blocks, LUKS/dm-crypt handles decryption transparently. No re-enroll needed.

### Diagnostic one-liners

```bash
# Quick filesystem health overview
sudo btrfs filesystem show
sudo btrfs filesystem df /var
sudo btrfs filesystem usage /var | head -25
sudo btrfs device stats /var

# All scrubs across all known mountpoints
for m in /var /etc /home /srv /home/user; do
    echo "=== $m ==="
    sudo btrfs scrub status "$m" 2>/dev/null || echo "(not a btrfs mountpoint)"
done

# Most fragmented files (top N) — helps decide what to defragment
sudo find /var/lib/containers -xdev -type f -print0 |
    xargs -0 -I{} filefrag {} 2>/dev/null |
    sort -t: -k2 -nr | head -20
```

---

## Snapshots + rollback (manual)

`/var` and `/home` are btrfs. Snapshots are operator-driven via the raw `btrfs subvolume` CLI — no snapper, no auto-snapshot timer:

```bash
sudo btrfs subvolume snapshot -r /var  /var/.snap/before-rebuild
sudo btrfs subvolume snapshot -r /home /home/.snap/pre-backup

# List
sudo btrfs subvolume list /var | grep .snap/

# Rollback: snapshot the live subvol aside, then swap. Or
# inspect the read-only snapshot and copy back selectively.
sudo btrfs subvolume delete /var/.snap/before-rebuild   # when done
```

---

## Backup + recovery

Only `/var`, `/home`, and persistent `/etc` are unique host state. The signed root and sysexts are reproducible from this repository plus release artifacts.

**Back up regularly:**
- `/home/user` — user data, dotfiles, project checkouts not already pushed elsewhere
- `/var/lib/containers` — rootless/system container state if it is not disposable
- `/var/lib/libvirt/images` — VM disks
- `/var/lib/incus` — Incus instances and images
- `/etc` — local config (hostname, NetworkManager state, sshd keys, crypttab additions, etc.); now a first-class persistent btrfs subvol on `data-luks`
- `/var/lib/extensions` — installed sysext images
- `/var/lib/sysupdate/` — cached release assets downloaded by `myosi update`
- LUKS recovery passphrase — store outside the machine; TPM2 is convenience, not backup

**Recovery paths:**

| Failure | Recovery |
|---------|----------|
| Bad base update | sd-boot boot counting should roll back after failed boots. Manual path: press Space at sd-boot menu and select the previous UKI/root slot. |
| Bad sysext | Run `sudo myosi extension-disable NAME`, or boot previous base / emergency shell and remove the bad image from `/var/lib/extensions/`, then reboot. |
| Broken local `/etc` file | Restore the verity-baked default: `cp /usr/share/factory/etc/<path> /etc/<path>` (the factory tree at `/usr/share/factory/etc` is the source `myosi-etc-seed.service` already used at first boot). For full reset of one subtree: `rm -rf /etc/<subdir>` then reboot — `myosi-etc-seed.service` does NOT re-fire on the missing subdir alone; you have to copy from `/usr/share/factory/etc/<subdir>` manually OR wipe all of `/etc` (see below). |
| Reset entire `/etc` to verity baseline | From recovery (or single-user mode): `mount /dev/mapper/data -o subvol=/,noatime /mnt && find /mnt/etc -mindepth 1 -xdev -delete && umount /mnt && reboot`. On next boot `ConditionDirectoryNotEmpty=!/sysroot/etc` is satisfied → `myosi-etc-seed.service` re-runs `cp -a /sysroot/usr/share/factory/etc/. /sysroot/etc/` → `/etc` returns to verity baseline. |
| Root corruption | dm-verity detects it. Boot the other slot or reinstall from the latest signed `myosi_*.raw.zst`; restore `/var` and `/home` from backup. |
| Lost LUKS passphrase, no TPM2 slot | Data is unrecoverable. Reinstall and restore from backup. |
| Lost LUKS passphrase, TPM2 still unlocks | Boot normally, then add a new passphrase with `systemd-cryptenroll --password <partition>`. |
| TPM2 unlock fails after firmware/SecureBoot change | Boot with the passphrase fallback, then `sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=7+14 /dev/disk/by-partlabel/data-luks` (re-enrolls TPM2 with current PCR values). |
| Failed data disk in btrfs pool | Use the profile-specific btrfs recovery path: `raid1`/`raid10` can be replaced, `raid0` normally requires restore from backup. |
| Lost boot disk but data disks intact | Reinstall base to a new boot disk, unlock/mount existing data pools, restore `/var`/`home` mappings, then re-enable required sysexts with `sudo myosi extension-enable`. |

---

## Default credentials + auth

| Account | Default password | Notes |
|---------|------------------|-------|
| `user` (UID 1000, fish, in wheel/kvm/video/render/input/libvirt/incus-admin) | `changeme` | Change immediately on first login |
| `root` | **LOCKED** (`!locked` in `/etc/shadow`) | No password. Bootstrap via `sudo passwd root` from user after first SSH/console login. |

Hashes are baked into `mkosi.extra/etc/shadow` (sha-512 + deterministic salt for reproducible builds). `systemd-sysusers` preserves shipped shadow entries on first boot, so the hash survives user creation.

`sysusers.d` has **no password column** in its format (6 fields: `TYPE NAME ID GECOS HOME SHELL`), so the only declarative path for shipping a default password is `/etc/shadow` itself. A 7th column triggers `Trailing garbage.` from `systemd-sysusers` and the entry is dropped — verified the hard way during the password-bootstrap refactor.

**Bootstrap flow on a fresh install:**
1. SSH in as `user` via a `fleet-keys` sysext-shipped public key.
2. `sudo passwd root` — sudo asks for user's password (`changeme`), then sets a real root password.
3. `passwd` — set a real user password.

`root` only ever has a password the operator sets manually post-install; the image never ships a known root credential.

**SSH:**
- Key-only (`PasswordAuthentication no`)
- No authorized keys ship in the public image. sshd reads four sources (`sshd_config.d/50-myosi.conf`): `~/.ssh/authorized_keys`, operator-managed `/etc/ssh/authorized_keys.d/<user>`, a baked `/usr/share/myosi/ssh/authorized_keys.d/<user>` (provide via private `mkosi.local.conf` `ExtraTrees=` overlay), and the `ssh.authorized_keys.<user>` systemd credential.
- Modern crypto only (curve25519, chacha20-poly1305, ed25519, no diffie-hellman-group14)
- `MaxAuthTries 3`, `LoginGraceTime 60`, no X11/UserEnv/UserRC

**sudo:** `%wheel ALL=(ALL) ALL`. `user` is in `wheel`. Prompts for password each `timestamp_timeout=15` minutes.

**Rootless podman:** `user` gets `subuid` + `subgid` range `100000:65536`; `root` gets `1000000:65536`.

---

## Hardening + tuning shipped in the base

Ported from `myos`, lives in `mkosi.extra/`. Active on every host.

### Kernel / sysctl (`/usr/lib/sysctl.d/50-myosi-performance.conf`)

| Knob | Value | Why |
|------|-------|-----|
| `vm.max_map_count` | 2147483642 | Wine/Proton games (Star Citizen, Tarkov, CS2) |
| `vm.swappiness` | 180 | zram-first; aggressive swap-to-zram |
| `vm.vfs_cache_pressure` | 50 | Keep more dir cache in RAM |
| `vm.watermark_scale_factor` | 500 | Aggressive reclaim |
| `vm.dirty_bytes` / `vm.dirty_background_bytes` | 256M / 128M | Predictable writeback |
| `vm.page-cluster` | 0 | Lower swap latency |
| `vm.compaction_proactiveness` | 0 | Don't burn CPU compacting |
| `fs.inotify.max_user_watches` | 524288 | IDEs, build tools |
| `fs.inotify.max_user_instances` | 8192 | Containers |
| `fs.file-max` | 2097152 | Servers, many containers |
| `net.core.default_qdisc` | `fq` | BBR companion |
| `net.ipv4.tcp_congestion_control` | `bbr` | Lower latency |
| `net.ipv6.conf.all.use_tempaddr` | 2 | IPv6 privacy extensions |
| `net.core.{r,w}mem_max` | 16777216 | VM networking buffers |
| `net.netfilter.nf_conntrack_max` | 262144 | Many concurrent flows |
| `kernel.sched_*` | tuned | Desktop responsiveness (EEVDF) |
| `kernel.nmi_watchdog` | 0 | ~1% CPU saving |
| `kernel.split_lock_mitigate` | 0 | Gaming perf |
| `kernel.unprivileged_userns_clone` | 1 | Required for Flatpak, podman |
| `kernel.printk` | `3 3 3 3` | Quiet console (no LUKS-prompt spam) |
| `kernel.kptr_restrict` | 2 | Hide kernel pointers from non-root |
| `kernel.dmesg_restrict` | 1 | dmesg root-only |
| `net.ipv4.ip_unprivileged_port_start` | 53 | Lets users bind 53+ (DNS, ssh-on-53) |

### zram (always-on, `/etc/systemd/zram-generator.conf`)

```
[zram0]
compression-algorithm = zstd
zram-fraction = 1.0       # device size = RAM size
max-zram-size = 16384     # capped at 16 GiB
```

`systemd-zram-generator` is a generator, not a service — runs every boot. No `systemctl enable` needed. Verify with `swapon --show`.

### I/O schedulers (`/usr/lib/udev/rules.d/60-ioschedulers.rules`)

| Device class | Scheduler |
|--------------|-----------|
| SSD + NVMe + eMMC SSD | `kyber` |
| HDD + SD card | `bfq` |
| virtio guest disks (`vd*`) | `mq-deadline` |
| loop devices | `none` |

### Other base configs

| File | Effect |
|------|--------|
| `/usr/lib/modprobe.d/kvm.conf` | `kvm halt_poll_ns=400000` — VM latency |
| `/etc/security/limits.d/memlock.conf` | 2GB memlock (PipeWire, Wine, containers) |
| `/etc/systemd/system.conf.d/10-timeout.conf` | `DefaultTimeoutStopSec=15s` — fast shutdown |
| `/etc/containers/containers.conf` | crun + sqlite + zstd:chunked + journald + **pasta** for rootless net |
| `/etc/profile.d/editor.sh` | `EDITOR=VISUAL=nvim` |
| `/etc/profile.d/gpg.sh` | `GPG_TTY` for ssh / tty agent |

### Kernel command line (baked into the signed UKI)

Built from `mkosi.conf` `KernelCommandLine=`. Highlights:
- `rd.systemd.verity=1` + `systemd.verity_root_options=panic-on-corruption,restart-on-corruption`
- `rd.luks.options=tpm2-device=auto,discard` + `rd.luks.timeout=120`
- `lockdown=integrity module.sig_enforce=1 init_on_alloc=1 init_on_free=1 slab_nomerge`
- `mitigations=auto,nosmt page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none debugfs=off`
- `selinux=1 enforcing=1`
- `systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all`
- `iommu=pt intel_iommu=on amd_iommu=on` (vendor-agnostic, kernel ignores wrong vendor)
- `module_blacklist=nouveau,nova_core,iTCO_wdt,iTCO_vendor_support,sp5100_tco` — single source of truth for "this module never loads" policy. UKI cmdline is the canonical home; modprobe.d files inside sysexts carry MODULE OPTIONS only.
- `transparent_hugepage=madvise`
- `quiet loglevel=3 console=ttyS0,115200n8 console=tty0`
- `audit=0` (SELinux covers most of it)

---

## Cheat sheet

### Dev host (`just` recipes — build, test, install)

```bash
# Build
just keys-generate                   # one-time signing keys + OVMF varstore
just build                           # base + all sub-images (incremental)
just clean

# Test
just qemu                            # full chain in qemu OVMF (interactive console)
just qemu-ssh                        # full chain with SSH access (headless-safe)
just qemu-ext                        # qemu + SSH + locally-staged sysexts injected
just nspawn                          # mkosi-managed nspawn boot (no UKI/verity/LUKS)

# Install (same script, target is whatever block device — USB or internal)
just install /dev/sdX                # boot USB from repo build
just install /dev/nvme0n1            # internal disk, auto-pick image
just install /dev/nvme0n1 /dev/sdb   # clone the booted USB onto NVMe
```

### Deployed host (`myosi` — operate)

The `myosi` wrapper only handles **myosi-specific orchestration**: sysupdate (private GitHub release), sysext feature management, and the install script. Everything else (LUKS keyslots, btrfs subvols, snapshots, portable services, credentials) is run with the upstream tool directly — see the §3 post-install runbook for the manual commands.

The wrapper scans `/usr/share/myosi/just/` (base modules `00-update.just`, `10-extensions.just`, `40-install.just`) and any sysext-provided modules (e.g. `50-virt.just`) at every invocation, emitting a transient justfile in `/run/myosi/`. Sysexts can add their own operator commands without the base image knowing about them. Run `myosi --list` to see what's currently available.

```bash
sudo myosi extension-enable   NAME [VERSION]   # enable a sysext feature
sudo myosi extension-disable  NAME             # disable a sysext feature
sudo myosi extension-list                      # installed + active sysext
sudo myosi update              [VERSION]       # fetch + apply
sudo myosi update --refresh    [VERSION]       # fetch + apply + live sysext refresh
sudo myosi fetch               [VERSION]       # fetch release artifacts
sudo myosi apply               [VERSION]       # apply cached artifacts
sudo myosi status                              # update + sysext state
sudo myosi vacuum                              # remove old generations
sudo myosi install             /dev/sdX [SRC]  # write a release to disk
```

Day-2 ops use upstream tools directly:

```bash
# LUKS keyslot management — see §3d
sudo cryptsetup luksAddKey --key-file /usr/share/myosi/keys/data.key \
    /dev/disk/by-partlabel/data-luks                       # add passphrase
sudo systemd-cryptenroll --wipe-slot=tpm2 \
    /dev/disk/by-partlabel/data-luks                       # remove TPM2

# btrfs pool — see §3i
sudo btrfs filesystem show /var
sudo btrfs balance start -dconvert=single -mconvert=raid1 -sconvert=raid1 /var

# Snapshots — see §14.2
sudo btrfs subvolume snapshot -r /home /home/.snap/<name>

# Factory-reset (wipes /var subvol contents — keeps verity root + sysexts)
sudo systemd-repart --can-factory-reset && sudo systemctl start factory-reset.target

# Portable services
sudo portablectl attach <image>
sudo portablectl list

# Encrypted system credentials
sudo systemd-creds encrypt --name=<name> - /etc/credstore.encrypted/<name>
sudo systemd-creds list
```

### Deployed host (native tools — day-2 ops)

Use the myosi wrapper for private-release updates. Use standard Linux tools for snapshots and inspection.

```bash
# Stage latest private GitHub release through local sysupdate cache
sudo myosi update
sudo reboot

# Optional live sysext activation without rebooting the running root
sudo myosi update --refresh

# Snapshots (raw btrfs, /var and /home are btrfs)
sudo btrfs subvolume snapshot -r /var  /var/.snap/before-rebuild
sudo btrfs subvolume snapshot -r /home /home/.snap/pre-backup
sudo btrfs subvolume list /var | grep .snap/

# Active sysexts
sudo systemd-sysext list
```

---

## Troubleshooting

### Black screen on hardware after selecting the myosi boot entry
- `console=tty0` must be the LAST `console=` on the kernel cmdline so the initrd LUKS passphrase prompt is visible on the laptop display. With `console=ttyS0,...` last, systemd renders prompts only on the serial port. Fixed in `mkosi.conf`; reflash if you've kept an older image.
- If the cmdline still has `quiet loglevel=3`, kernel boot messages are suppressed — at the sd-boot menu press **`e`** and remove `quiet` to see why it's stuck.

### `myosi-data-attach.service` fails during boot
- The initrd needs `/dev/mapper/data` unlocked before `switch_root` because both `/sysroot/var` and `/sysroot/etc` are btrfs subvolumes on it. Check:
  - The root disk has exactly one DPS `Type=var` partition.
  - `/usr/share/myosi/keys/data.key` exists in the initrd (or a TPM2/passphrase keyslot is enrolled).
  - `systemd-repart.service` completed successfully or exited with the whitelisted no-free-space code.
  - `StandardOutput=journal+console` on the service ensures errors reach the framebuffer — check `journalctl -b` from an emergency shell.

### `sysroot-etc.mount` unmounted by initrd-cleanup isolate
- `initrd-cleanup.service` runs `systemctl --no-block isolate initrd-switch-root.target` seconds before the pivot. Without `IgnoreOnIsolate=yes`, the mount is stopped and the kernel pivots into an empty `/etc`. Fixed by setting `IgnoreOnIsolate=yes` on `sysroot-etc.mount`; ordering is maintained via `After=myosi-data-attach.service` and `Requires=` on the parent `initrd-fs.target`.

### `/dev/mapper/data` or `/var` is only ~240 MiB after install
- The data partition should grow in the initrd before pivot. If it stays tiny, inspect `journalctl -b -u systemd-repart.service -u myosi-data-attach.service` from the failed boot or emergency shell.

### `mokutil --import` rejects `/usr/share/myosi/keys/{boot,image}.crt` with `not a valid x509 certificate in DER format`
- mokutil only accepts DER. Recent builds ship both `.crt` (PEM) and `.der` (DER) — use `sudo mokutil --import /usr/share/myosi/keys/{boot,image}.der`. On older builds: `sudo openssl x509 -in /usr/share/myosi/keys/boot.crt -outform DER -out /tmp/boot.der` (the base image now ships `openssl`), same for `image`.

### `/usr/share/myosi/keys/` is empty
- `BuildSources=keys` without an explicit destination flattens `./keys/` into `$SRCDIR/` instead of `$SRCDIR/keys/`, so `mkosi.postinst`'s cert-copy step silently no-ops. Fixed by `BuildSources=keys:keys`. Rebuild + reflash.

### Sysexts fail to merge with a verity signature error
- The kernel has no trusted `image.der`. Enroll `/efi/keys/image.der` into firmware db, or MOK-enroll `/usr/share/myosi/keys/image.der` with `mokutil --import`. Reboot, then verify with `sudo keyctl list %:.platform` and `sudo keyctl list %:.machine`. Unsigned sysexts are possible by changing `mkosi.shared/sysext.conf` from `Verity=signed` to `Verity=yes`, but then you keep Merkle-tree integrity without the PKCS#7 authenticity check.

### Login as `user` rejects `changeme`
- nspawn was launched with `--read-only` instead of `--volatile=overlay`. Without overlay, `/etc/shadow` is RO and systemd-sysusers can't write the hash. Re-launch with `--volatile=overlay`.

### `systemd-nspawn --image=` fails with "Failed to load Verity signature partition: No data available"
- Host kernel `.platform` keyring doesn't trust our `image.crt`. Expected on test hosts. Use the loop-mount + `--directory` + `--volatile=overlay` path documented above.

### `Failed to start sshd.service` in nspawn
- nspawn-specific. sshd-keygen needs entropy + TPM; nspawn doesn't expose them. Real hardware boot works.

### `podman: overlay is not supported over overlayfs`
- nspawn artifact. Root is mounted as overlay, podman storage default driver can't stack. Real `/var/lib/containers` (btrfs) works.

### `mkosi.images/nvidia*` builds fail with cascading `va_list unknown type` / `dma_is_direct implicit declaration` errors
- Looks like an upstream source incompatibility, isn't. mkosi's postinst sandbox runs `chroot $BUILDROOT rpmbuild ...` without propagating `/dev` (real char devices) or `/proc`. NVIDIA's `nvidia-kmod` conftest probes redirect gcc stderr into a generated `macros.h`; without a real `/dev/null` the redirect lands on garbage and every downstream compile blows up. Fixed by bind-mounting `/dev` + `/proc` into the buildroot via `mkosi.shared/kmod-build.sh` (`kmod_exec` wrapper) before `chroot rpmbuild`. Both branches now build cleanly against kernel 7.0.10-201.fc44 — myos's bootc build never hit this because podman provides real device nodes.

### OpenZFS sysext doesn't compile after a kernel/Fedora bump
- OpenZFS upstream typically trails new kernels by 2-6 weeks. The build script uses an upstream-tarball flow (`mkosi.shared/zfs-build.sh`) with `ZFS_VERSION` env var pointing at the GitHub release tag. Two recovery paths:
  - **Bump `ZFS_VERSION`** in `zfs-build.sh` once OpenZFS publishes a release whose META `Linux-Maximum` covers the new kernel. One-line change.
  - **`ZFS_BUILD_OPTIONAL=1` in CI**, which makes `dnf install`, tarball fetch, configure, and rpmbuild failures non-fatal. The postinst exits 0 with an empty sysext stub; CI keeps shipping every other artifact and deployed hosts stay on their last working zfs sysext via systemd-sysext version precedence.

### `just build` from distrobox errors `"You must run systemctl inside a container!"`
- A symlink from `distrobox-host-exec` to `systemctl` was misdirecting. Remove the symlink; mkosi calls real systemd via `distrobox-host-exec systemctl`.

### Image too large (~17 GB compressed)
- Was caused by `mkosi.extra/usr/lib/repart.d/90-data.conf SizeMinBytes=16G`. Fixed in v0.1+: now `SizeMinBytes=256M` and no `SizeMaxBytes`, so the data partition grows to fill disk on first boot. Shipped image ≈ 700 MB.

---

## Key decisions (FAQ)

**Why mkosi instead of bootc?**
mkosi composes signed disk images directly from upstream systemd primitives — repart, sysext, sysupdate, ukify, dm-verity, LUKS2. No ostree, no composefs, no rpm-ostree. The full A/B + signing model lives in plain `.conf` files. Easier to reason about, audit, and rebuild from scratch.

**Why dm-verity + erofs instead of composefs (fs-verity)?**
dm-verity provides partition-level Merkle-tree signing — the whole root data partition is integrity-guarded by one signed root hash. Any block tampering returns I/O error and kills the kernel (`panic-on-corruption`). erofs is RO by design, mmap-friendly, well-compressed, integrates cleanly with verity.

**Why `UnifiedKernelImages=auto` and not `=signed`?**
`=signed` expects a pre-signed UKI at `/usr/lib/modules/<kver>/uki.efi` produced by distribution kernel-install hooks. Those hooks need systemd / `machinectl` / live `/proc` — none of which exist in mkosi's user-namespace sandbox. `=auto` tells mkosi to generate + sign the UKI itself via `ukify`. The output is functionally equivalent (signed PE binary with kernel + initramfs + cmdline).

**Why is `image.key` RSA-4096?**
`boot.key` is RSA-4096 because UEFI SecureBoot tooling expects PE/Authenticode-compatible signatures. `image.key` is separate and signs dm-verity, and sysext image metadata; RSA-4096 is used there too because the dm-verity signature path wraps root hashes in PKCS#7/CMS.

**Why ship `/etc/shadow` and not generate users via sysusers.d?**
sysusers.d `u` type only accepts UIDs in the system range (< 1000). Asking for UID 1000 silently falls back to auto-allocation + locked password + nologin shell. Shipping `/etc/shadow` with the hash works the same way `myos` does in its bootc image. sysusers still creates the user (UID, groups, shell), preserving the shipped hash.

**Why ship baseline config in `/etc/`?**
sshd, sudo, podman, NetworkManager, and firewalld read their active config from `/etc/`. myosi therefore seeds security-sensitive defaults in `mkosi.extra/etc/` as the verity-protected baseline, `mkosi.finalize` snapshots that baseline to `/usr/share/factory/etc` (the verity-baked factory tree), and `myosi-etc-seed.service` copies it into the empty `/etc` subvol on first boot only. Subsequent boots skip the seed (`ConditionDirectoryNotEmpty=!/sysroot/etc` gate); operator owns `/etc` afterwards. Reusable signed configuration ships as sysexts under `/usr` instead of stacking a confext layer (see `fleet-keys`).

**Why `vm.swappiness=180`?**
zram is always-on. Swap pages go to zstd-compressed RAM, not disk. Aggressive swappiness is correct in that regime. Without zram, 180 would thrash to disk; with it, you get effective memory compression.

**Why one base image instead of per-host images like myos?**
A slim signed base + per-host opt-in sysexts means every host runs the same updateable artifact. Per-host images multiply the update + signing surface. Host identity lives in the persistent `/etc` btrfs subvol on `data-luks`; reusable signed configuration ships as additional sysexts under `/usr` (e.g. `fleet-keys`).

**Why pasta instead of slirp4netns for rootless podman?**
slirp4netns works but is slow, IPv6-limited, and the legacy default. pasta (passt) is faster (kernel-based packet shuttling), has full IPv6 support, and is the default in podman 5.x+. Configured via `default_rootless_network_cmd = "pasta"` in `/etc/containers/containers.conf`. myos uses slirp4netns — myosi deliberately diverges.

**Why is `/etc` writable when the rest of the root is RO?**
systemd-sysusers, systemd-machine-id-commit, sshd-keygen, NetworkManager, and password changes need writable `/etc` at runtime. myosi keeps `/etc` as a real persistent btrfs subvolume on `data-luks`, seeded from the verity-baked `/usr/share/factory/etc` factory tree by `myosi-etc-seed.service` (initrd) on first boot only. Host-owned config should still prefer signed sysexts; local `/etc` edits are for machine-local state and emergency overrides.

**Why is `/etc` a btrfs subvol instead of an overlay over `/usr/share/factory/etc`?**
The earlier overlay model (`lowerdir=/usr/share/factory/etc`, `upperdir=/var/etc`) had three structural problems that the subvol replacement fixes at once: (1) the overlay pinned `/var` open at shutdown — PID 1 held file descriptors on `/etc` files through the overlay, so `umount2(0)` on `var.mount` returned EBUSY and the unit logged FAILED; (2) overlayfs caches the upperdir's SELinux context at mount time, so a first-boot `restorecon` race was unavoidable and required a `setfattr` pass + `myosi-firstboot-relabel.service` to win it; (3) overlay copy-up on first write to a `/usr/share/factory/etc/...` path persisted stale content into `/var/etc/` across image upgrades. With `/etc` as a plain btrfs subvol mounted directly: shutdown unmounts cleanly (no overlay between PID 1 and `data-luks`), SELinux labels inherit from the copy source at `myosi-etc-seed.service` time (no race), and operator-modified `/etc` files persist untouched across image upgrades. Trade-off: new factory defaults in `/usr/share/factory/etc/` on later images are NOT auto-merged into `/etc` (same bootc-style "operator owns /etc" semantic), so operators run `diff -ruN /etc /usr/share/factory/etc` after upgrades to spot drift they care about.

**Why does `myosi-data-attach` use `udevadm info` instead of `blkid` for partition metadata?**
`blkid -s PART_ENTRY_TYPE` silently exits 2 on dm-verity-backed partitions — it tries to probe the filesystem layer and aborts before reporting partition-table metadata. `udevadm info --query=property` reads `ID_PART_ENTRY_TYPE`/`ID_PART_ENTRY_NAME` from udev's per-device DB, which is populated at coldplug time from the parent disk's partition table. Since `udevadm settle` runs before partition discovery, the values are always available. The helper also parses the property dump with pure bash (`IFS='=' read`) because mkosi-initrd ships no awk/grep/cut.

**Why does `sysroot-etc.mount` have `IgnoreOnIsolate=yes`?**
`initrd-cleanup.service` runs `systemctl --no-block isolate initrd-switch-root.target` seconds before the pivot. This isolate stops every unit not pulled in by the target. Without `IgnoreOnIsolate=yes`, `sysroot-etc.mount` would be stopped seconds before pivot — the kernel would switch root into an empty `/etc`, SELinux policy load would fail, and pid 1 would freeze. With `IgnoreOnIsolate=yes`, the mount survives the isolate. The parent `initrd-fs.target` `Requires=` it, so a start-time failure still surfaces in the emergency shell.

**Why isn't `/var` mounted in the initrd?**
Nothing in the initrd phase reads `/var`, and `systemd-gpt-auto-generator` already emits `var.mount` post-pivot from the DPS `Type=var` partition. With `DefaultSubvolume=/var` in `90-data.conf`, the auto-generated mount uses the correct btrfs subvolume automatically. Same lifecycle as `home.mount` and `srv.mount`. `/etc` is the special case — PID 1 reads `/etc/selinux/config` + `/etc/systemd/system.conf` synchronously at startup, so the mount must fire before pivot.

**Why is there a single `install.sh` for USB flashing AND disk install?**
Writing a myosi image to a USB stick and installing it on an internal disk are the same operation: `dd` a full GPT image to a block device. The earlier split between `flash-usb.sh` and `install-to-disk.sh` was duplication. One script (`install/install.sh`, surfaced as `just install <device> [<source>]`) auto-detects the source (repo `build/`, `/run/myosi-installer/`, or the live disk itself when run inside a booted USB) and writes whatever destination you point at.

**Why are signing certs shipped at `/usr/share/myosi/keys/` in both PEM and DER?**
PEM (`*.crt`) is the canonical OpenSSL-readable form (`openssl x509 -in ... -noout -text`). DER (`*.der`) is what `mokutil --import` requires — the tool rejects PEM with a generic `not a valid x509 certificate in DER format`. `mkosi.postinst` derives the DER once at build time via `openssl x509 -outform DER` so the operator never has to convert anything to enroll a cert. The base image also includes `openssl` for the operator's own conversion needs.

**Why are operator commands at `/usr/libexec/myosi/` instead of `just` recipes?**
Deployed hosts don't have `just`. They don't have the repo. Operator commands that touch host state (extension enable/disable, pool grow, MOK enroll, data-luks keyslot management) belong on the host, not in the dev workflow. `just` recipes stay in the repo for the dev-host build/test loop; the libexec scripts are the real production interface.

**Why no Nix or Homebrew preinstalled in the base?**
Intentional. `myosi` is an atomic, signed OS — installing arbitrary user-space package managers into the image undermines that. Dev tools live in a distrobox dev container with Nix + Homebrew + Brewfile-managed CLIs. The base ships the minimum for a functional host (fish, neovim, ripgrep, fzf, etc.). Heavier dev workflows enter distrobox.

---

## Status + milestones

| Milestone | Status |
|-----------|--------|
| **v1: scaffolding** | ✅ done — slim base + sysexts (desktop, containers, firmware, virt, nvidia*); signing infra; transfer defs; install scripts; CI workflow. Earlier drafts shipped per-host confexts as the default; the confext layer has since been retired (single `/etc` overlay), and all reusable signed configuration ships as sysexts under `/usr`. |
| **v1.1: declarative passwd + base hardening** | ✅ done — sysusers + shipped shadow + subuid/subgid + sudo + sysctl + ssh + zram + modprobe + udev |
| **v1.2: writable /etc in real initrd** | ✅ done — cpio sub-image `mkosi.images/initrd/` (Include=mkosi-initrd, bash+cryptsetup+btrfs-progs+util-linux+attr); `myosi-data-attach.service` finds root disk, selects its `Type=var` partition, unlocks as `/dev/mapper/data` (key-file probe → TPM2/passphrase fallback), unlocks `data-N` pool members across ANY disk, scans btrfs, seeds + labels the `/etc` subvol; `sysroot-etc.mount` mounts `/etc` btrfs subvolume (`IgnoreOnIsolate=yes` to survive initrd-cleanup isolate); `initrd-fs.target` `Requires=` it. `/var` is mounted post-pivot by gpt-auto-generator (Type=var + DefaultSubvolume=/var), same lifecycle as home.mount and srv.mount. Uses `udevadm info` for partition metadata (blkid exits 2 on dm-verity partitions). No `/etc/fstab` or `/etc/crypttab` in the sealed root — all unlock/mount declarative. **The initial overlayfs `/etc` (lower=`/usr/share/factory/etc`, upper=`/var/etc`) was retired in favor of `/etc` as a real persistent btrfs subvolume seeded from `/usr/share/factory/etc` by `myosi-data-attach` in the initrd.**
| **v1.3: signed kernel modules + module blacklist on UKI cmdline** | ✅ done — every `nvidia*.ko` / `zfs.ko` / `spl.ko` signed with `boot.key`; `module_blacklist=` baked into UKI cmdline as the single canonical blacklist source. |
| **v1.4: NVIDIA sysexts working** | ✅ done — both `nvidia` (595.x open, Turing+) and `nvidia-580xx` (580.x proprietary, Pascal/Maxwell/Volta) build cleanly against kernel 7.0.10. Root cause was missing `/dev` + `/proc` in mkosi sandbox chroot, fixed via `mkosi.shared/kmod-build.sh`. |
| **v1.5: OpenZFS sysext via upstream tarball** | ✅ done — `zfs-build.sh` pulls `zfs-${ZFS_VERSION}.tar.gz`, generates SRPMs with `make srpm-utils srpm-kmod`, rebuilds via `kmod_exec rpmbuild`, signs `zfs.ko` + `spl.ko`. No dependency on zfsonlinux.org/fedora packaging that lags new Fedora releases. |
| **v1.6: fleet-keys sysext baked into base** | ✅ done (since retired — the public repo ships no keys; see SSH hardening section) — `/usr/lib/extensions/fleet-keys_VER_ARCH.raw` ships in the verity-protected root for first-boot SSH; sysupdate rotations land in `/var/lib/extensions/` and win precedence. Originally shipped as a confext; reworked as a sysext that drops `authorized_keys` under `/usr/share/myosi/ssh/authorized_keys.d/` and is read by sshd via an `AuthorizedKeysFile` token. |
| **v1.7: prerelease versioning + bare tags** | ✅ done — `YYYY.MM.DD.NN` for stable, `-rc.N` / `-beta.N` / `-alpha.N` for prereleases. No `v` prefix anywhere — filenames + tags identical. CI workflow `prerelease` input validates `(alpha|beta|rc)\.N`. |
| **v1.8: locked root + bootstrap via user sudo** | ✅ done — root ships `!locked` in shadow; user has `changeme`. First-login `sudo passwd root` sets a real root password. Image never ships a known root credential. |
| **v1.9: incremental build mode** | ✅ done — `just build` runs `mkosi -fi` for fast local iteration; `just build full` runs `mkosi -ff` for clean releases; CI workflow pinned to full. |
| **v2: real-hardware install** | ⬜ pending — dd → USB → install → boot a sacrificial target |
| **v3: sysupdate end-to-end** | ✅ done — private GitHub releases are fetched by `myosi update` into `/var/lib/sysupdate`, then applied by updatectl from local files. |
| **v4: TPM2 enrollment + dual SecureBoot validation** | ⬜ pending |
| **v5: fleet rollout** | ⬜ pending — replace `myos` on remaining hosts |
| **v6: public artifact store decision** | ✅ deferred by design — no public artifact store required. Private GitHub access stays in the `gh`-backed cache fetcher; sysupdate consumes only local files. |

---

## See also

- **Design notes** section below — full architecture, partition layout, boot chain, threat model
- **Signing keys** section below — key generation + rotation runbook
- **Multi-disk storage runbook** appendix below — manual install + multi-disk patterns
- `../myos/README.md` — sibling bootc project (will eventually be superseded by myosi)

---


---

# Build + test (developer / contributor)

The build and qemu-test workflow lives at the end of this README to
keep the operator-facing install / configure / troubleshoot path up
front. Only needed if you're rebuilding myosi from source.

## Quickstart — developer (local build)

```bash
# One-time setup
cd myosi
just keys-generate       # creates keys/{boot,image}.{key,crt}

# Build everything (base + sysexts)
#
# Two modes:
#   just build           → dev/incremental (default) — `mkosi -fi build`. Reuses
#                          cached sub-image final trees from mkosi.builddir/;
#                          only postinst-touched sub-images actually re-run.
#                          ~3-5 min when only one sub-image changed.
#   just build full      → clean rebuild — `mkosi -ff build`. ~25-40 min on
#                          8-core, 16G RAM. CI / release always uses full.
just build
just build full

# There is no `build-sub`. mkosi -C standalone sub-image builds don't
# inherit top-level Validation/BuildSources/Dependencies, so they fail.
# Iterate via top-level `just build`; incremental mode makes per-sub-image
# rebuild loops cheap.

# Package sets are declared directly in mkosi.conf.d/ files.
# Runtime repart definitions live once in mkosi.extra/usr/lib/repart.d/ and are copied into the initrd via ExtraTrees.

# Wipe outputs
just clean
```

Outputs land in `build/`. The `_VERSION` suffix is `YYYY.MM.DD.NN` for stable builds — date plus a same-day build counter that auto-increments on each `just build` and resets to `.01` on a new day (e.g. first build of 2026-05-30 = `2026.05.30.01`, second = `2026.05.30.02`). Prerelease builds add a SemVer-style suffix: `YYYY.MM.DD.NN-rc.N`, `-beta.N`, or `-alpha.N` (e.g. `2026.05.30.01-rc.1`). Override the whole version via `MYOSI_VERSION=...`. Counter state lives in `build/.version-counter`.

---

## Quickstart — testing the image

myosi is dm-verity-signed end-to-end. Four test methods, each exercising a deeper layer of the stack. Start with the fastest iteration loop (nspawn), confirm the full boot chain in qemu last.

### Test methods comparison

| Method | Boot chain | dm-verity | LUKS | SSH | Extensions | Typical cycle | Headless |
|--------|-----------|-----------|------|-----|------------|---------------|----------|
| **Offline inspection** | none | no | no | no | yes (structure only) | < 1 min | yes |
| **systemd-nspawn** | none | no | no | no | yes (if bound) | < 2 min | yes |
| **qemu headless (SSH)** | **full** | **yes** | **yes** | **yes** | yes (--runtime-tree) | ~2-5 min | **yes** |
| **qemu interactive (console)** | **full** | **yes** | **yes** | no (unless set up) | yes (--runtime-tree) | ~2-5 min | via tmux |

---

### 1. Inspect raw image contents (offline)

Fastest sanity check. No boot, no kernel, just peek at the filesystem.

```bash
zstd -d build/myosi_*.raw.zst -o /tmp/myosi.raw
sudo losetup -fP --show /tmp/myosi.raw

LOOP=$(losetup -j /tmp/myosi.raw | head -1 | cut -d: -f1)
sudo mount -t erofs -o ro ${LOOP}p2 /mnt/myosi-root

# Verify shipped config
ls /mnt/myosi-root/etc/ssh/sshd_config.d/
cat /mnt/myosi-root/etc/shadow
cat /mnt/myosi-root/etc/os-release       # ID=myosi
# Verify shipped config (no /etc/fstab or /etc/crypttab in sealed root)
ls /mnt/myosi-root/usr/lib/repart.d/
ls /mnt/myosi-root/usr/lib/sysupdate.d/

# Verify the initrd carries the /var + /etc mount units + data-attach
zstdcat build/initrd.cpio.zst | cpio -it 2>/dev/null | grep -E 'myosi-data-attach|sysroot-etc\.mount'

# Cleanup
sudo umount /mnt/myosi-root
sudo losetup -d "$LOOP"
```

---

### 2. systemd-nspawn (userspace smoke test)

Fastest boot. Host kernel shared — **no** UEFI, UKI, dm-verity, or LUKS exercise. Best for iterating on userspace config, sysusers, services, login.

**Why `--directory` not `--image`:** the host kernel cannot validate our verity signature unless `image.crt` is in its `.platform` keyring (populated from UEFI db at boot on installed hosts). We loop-mount the erofs partition manually and point nspawn at the directory.

```bash
# After offline inspection loop-mount above
sudo systemd-nspawn \
    --directory=/mnt/myosi-root \
    --volatile=overlay \
    --boot \
    --machine=myositest \
    --resolv-conf=copy-host
```

`--volatile=overlay` is critical — root mounts read-only from erofs; this adds a tmpfs overlay so `systemd-sysusers` can write `/etc/shadow` and `/etc/machine-id`.

Inside the container:
- Login: `user` / `changeme` (root is shipped LOCKED — see "Default credentials" below).

```bash
# Verification
id                                  # uid=1000(user), groups wheel,kvm,...
sudo -l                             # wheel rule
cat /etc/os-release                 # ID=myosi
swapon --show                       # zram0 partition
sysctl vm.swappiness vm.max_map_count fs.inotify.max_user_watches
```

**Known nspawn artifacts (ignore):**
- `sshd.service` fails — no TPM, no /dev/random entropy source in nspawn
- `systemd-homed`, `logind` may fail with `--volatile=overlay`
- `podman: overlay is not supported over overlayfs` — nspawn root is overlay; real `/var/lib/containers` on btrfs works

---

### 3. QEMU / OVMF (full chain test)

Exercises the complete production boot path: UEFI firmware → shim → sd-boot → signed UKI → dm-verity root → LUKS unlock → `/var` + `/etc` btrfs subvols → switch_root → sysext merge.

Two access modes: **headless via SSH** (no rebuild, works over SSH sessions) and **interactive via console** (rebuild required for autologin).

#### 3a. Prerequisites

- **KVM accessible:** `test -r /dev/kvm && echo yes || echo no`
- **mkosi ≥ 26** (already installed in the dev distrobox)
- **tmux** (if running over SSH — keeps the VM alive when you disconnect)
- Image already built: `ls build/myosi_*`

#### 3b. Headless boot via mkosi SSH (recommended)

mkosi v26 injects SSH keys at boot via systemd credentials. No rebuild needed — works with the existing signed image. Connect via `mkosi ssh` over AF_VSOCK.

```bash
# One-time: generate SSH keypair for mkosi
mkosi genkey

# Start the VM in a tmux session (survives SSH disconnect)
tmux new -s myosi-vm
mkosi vm --ssh=runtime --cpus=4 --ram=8G
# Ctrl-b d  to detach from tmux
```

The VM boots with full UEFI chain. You'll see serial console output in tmux. On first boot, the LUKS passphrase prompt appears — type a passphrase (it becomes the LUKS key).

Wait for boot to complete (`multi-user.target` reached), then connect:

```bash
# Open a second terminal (or detach tmux first)
mkosi ssh                          # root shell inside the VM

# From inside the VM:
passwd user                   # set user password
su - user                     # switch to user
```

If you need the console directly:
```bash
tmux attach -t myosi-vm            # reattach to serial console
```

**Verification from SSH:**
```bash
mkosi ssh -- cat /proc/cmdline | tr ' ' '\n' | head -20
# Should show: rootfstype=erofs, rd.systemd.verity=1, lockdown=integrity, ...

mkosi ssh -- systemd-dissect --discover
mkosi ssh -- veritysetup status root
mkosi ssh -- mount | grep -E 'erofs|overlay|btrfs'
# Should show:
#   /dev/mapper/root on / type erofs (ro,...)
#   myosi-etc-overlay on /etc type overlay (rw,...)
#   /dev/mapper/data on /var type btrfs (rw,...)

mkosi ssh -- swapon --show
# Should show: /dev/zram0 partition

mkosi ssh -- systemctl status sshd
# Should be active — real kernel, real TPM, real entropy
```

**Shutdown:**
```bash
mkosi ssh -- systemctl poweroff
# OR from tmux: press Ctrl-a c then type 'quit' at qemu monitor
# OR just kill the tmux window (state is on a tmpfs overlay, not persistent)
```

#### 3c. Interactive boot via console (with autologin)

Useful when you want direct console access without SSH. Requires a rebuild to bake in autologin.

```bash
# Copy local QEMU defaults, then explicitly enable test-only autologin
cp mkosi.local.conf.example mkosi.local.conf
printf '\n[Content]\nAutologin=yes\n' >> mkosi.local.conf

# Rebuild with autologin (~5 min, incremental cache from previous build)
mkosi -f build

# Boot in tmux
tmux new -s myosi-vm
mkosi vm --cpus=4 --ram=8G
```

You'll see the full boot sequence in the terminal, ending at a root shell (autologin on tty1). Set up user password:
```bash
passwd user
```

#### 3d. Injecting sysexts at boot

No rebuild. Stage extensions on the host, bind-mount them into the VM at boot via `--runtime-tree`:

```bash
# Stage extensions from the build directory
VERSION=$(ls build/ | grep -oP '\d{4}\.\d{2}\.\d{2}\.\d{2}' | head -1)
mkdir -p /tmp/myosi-extensions
cp build/firmware_${VERSION}.raw /tmp/myosi-extensions/
cp build/virt_${VERSION}_${ARCH}.raw      /tmp/myosi-extensions/

# Boot with extensions injected
mkosi vm --ssh=runtime --cpus=4 --ram=8G \
  --runtime-tree=/tmp/myosi-extensions:/var/lib/extensions
```

Then verify from SSH:
```bash
mkosi ssh -- systemd-sysext status
mkosi ssh -- systemd-sysext list
# Should list virt and any other enabled sysexts

mkosi ssh -- cat /etc/hostname
# Shows the writable /etc overlay hostname (set via hostnamectl)
```

**Signature trust note:** qemu VMs booted with `mkosi vm` use the pre-enrolled OVMF varstore at `keys/OVMF_VARS-enrolled.fd`, which has both `boot.crt` and `image.crt` in db. The kernel picks both up into `.platform` at init (CONFIG_LOAD_UEFI_KEYS), and dm-verity validates root + sysext signatures directly against `.platform`. Signature validation works out of the box for qemu — no manual MOK enrollment needed.

#### 3e. Full verification checklist

After boot, verify each layer of the stack:

```bash
# 1. Kernel command line
cat /proc/cmdline | tr ' ' '\n'
# Expected: rootfstype=erofs, rd.systemd.verity=1, lockdown=integrity,
#           selinux=1 enforcing=1, module.sig_enforce=1, ...

# 2. Root integrity
dmsetup table root | head -1
# Should contain: verity <version> <hash_start> <data_dev> <hash_dev> <data_blk> <hash_blk> ...
veritysetup status root
# Should show:  VERITY    active

# 3. /etc writable overlay
findmnt /etc
# Should show: overlay  myosi-etc-overlay  ... rw,relatime,lowerdir=...,upperdir=...,workdir=...

# 4. /usr read-only
findmnt /usr
touch /usr/test 2>&1
# Should fail: Read-only file system

# 5. /var + /home on encrypted btrfs
findmnt /var | grep btrfs
findmnt /home | grep btrfs
btrfs subvolume list /var
# Should list: /var, /var/tmp, /var/cache, /var/log, /var/lib/containers, /home, ...

# 6. zram active
swapon --show
# Should show: /dev/zram0  partition  ...

# 7. Users and groups
id user
# uid=1000(user) gid=1000 groups=1000,10(wheel),39(video),...

# 8. Hardening sysctl
sysctl kernel.kptr_restrict        # 2
sysctl kernel.dmesg_restrict       # 1
sysctl vm.swappiness               # 180
sysctl net.ipv4.tcp_congestion_control  # bbr

# 9. SSH access (only in qemu, not nspawn)
systemctl status sshd
ss -tlnp | grep :22

# 10. Extensions (if injected)
systemd-sysext list
```

---

### 4. Sysext testing

#### Offline inspection

```bash
sudo systemd-dissect build/firmware_*.raw
# Shows: type=sysext, image_id=virt, extension-release metadata

sudo systemd-dissect --list build/firmware_*.raw | head -30
# Lists all files in the extension
```

#### In qemu (see §3d)

Inject with `--runtime-tree` at boot. No rebuild, works with signed images, full signature validation.

#### In nspawn

Bind-mount extensions into a running nspawn instance:

```bash
# Stage extensions
mkdir -p /tmp/myosi-extensions
cp build/firmware_*.raw /tmp/myosi-extensions/

# Boot nspawn with extensions bound
sudo systemd-nspawn \
    --directory=/mnt/myosi-root \
    --volatile=overlay \
    --bind=/tmp/myosi-extensions:/var/lib/extensions \
    --boot --machine=myositest --resolv-conf=copy-host
```

Inside nspawn, trigger extension merge manually (auto-merge runs at boot but may fail silently because the host kernel `.platform` doesn't trust our `image.crt`). Signature validation is expected to fail in nspawn — the host kernel doesn't trust our `image.crt`.

```bash
systemd-sysext status
systemd-sysext list
journalctl -u systemd-sysext.service
```

---

### 5. Headless workflow cheatsheet

Reference for testing from a headless host over SSH (e.g. a server in distrobox):

```bash
# ── One-time setup ──
mkosi genkey                              # generate SSH keys for mkosi ssh

# ── Boot VM ──
tmux new -s myosi-vm                      # create persistent session
mkosi vm --ssh=runtime --cpus=4 --ram=8G  # boot full UEFI chain
#  → Type LUKS passphrase at prompt (first boot only)
#  → Ctrl-b d to detach

# ── Connect ──
mkosi ssh                                 # root shell via AF_VSOCK
mkosi ssh -- su - user               # user shell
mkosi ssh -- cat /proc/cmdline            # one-shot command
tmux attach -t myosi-vm                   # reattach to serial console

# ── With extensions ──
mkdir -p /tmp/myosi-extensions
cp build/firmware_*.raw /tmp/myosi-extensions/
mkosi vm --ssh=runtime --cpus=4 --ram=8G \
  --runtime-tree=/tmp/myosi-extensions:/var/lib/extensions

# ── Journal ──
mkosi journalctl -u systemd-sysext -n 50
mkosi journalctl -b                        # full boot log

# ── Shutdown ──
mkosi ssh -- systemctl poweroff
tmux kill-session -t myosi-vm             # force kill if stuck
```

**Common pitfalls in headless qemu:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| `mkosi ssh` times out | VM still booting, or SSH key not injected | Wait 15-30s after boot; ensure `--ssh=runtime` was passed |
| Console stuck at LUKS prompt | First boot needs passphrase | Attach tmux, type passphrase once |
| `KVM not available` | Running in a container without /dev/kvm | Use `distrobox-host-exec` or run outside distrobox |
| `mkosi vm` exits immediately | Previous build state stale | Run `mkosi clean` then `mkosi -f build` |
| Extensions not merging | Signature validation fails | Expected in nspawn; in qemu auto-enrolled keys should work. Check `journalctl -u systemd-sysext` |
| `ssh: connect to host ... port 22: Connection refused` | Using regular SSH instead of `mkosi ssh` | Use `mkosi ssh` (connects via AF_VSOCK, not TCP) |

---

# Recent changes (2026.06.06–07)

Significant fixes and architectural changes landed across the last
release cycles. Operators upgrading from earlier `.02` should be
aware of these.

## PartitionUUID encoding in artifact filenames (commit `4f...`)

Symptom on the 2026.06.06.04 release: hosts that upgraded via
`sudo myosi update` rebooted into emergency mode with `dev-mapper-root.device`
timeout. Root cause: `systemd-sysupdate` writes new partition content
during A/B updates but does NOT update the destination GPT
PartitionUUID unless the source filename embeds the UUID via the
`@u` wildcard. The kernel cmdline's `roothash=` lookup (per the
Discoverable Partitions Spec) then resolves to the wrong partition.

Fix:

1. `mkosi.extra/usr/lib/sysupdate.d/10-root.transfer` and
   `11-verity.transfer` now use
   `MatchPattern=myosi_@v_%a_@u.<kind>.raw.zst`.
2. After `mkosi build` finishes, `myosi/scripts/stage-artifacts.sh`
   reads the freshly built UKI's roothash via `ukify inspect`, splits
   it into root + verity UUIDs (first/last 16 bytes per Discoverable
   Partitions Spec), and renames the `.raw.zst` files in `build/` to
   embed the UUIDs.
3. Both `just build` and the GitHub Actions workflow invoke
   `scripts/stage-artifacts.sh` explicitly after `mkosi build`.
   Earlier attempts used `mkosi.finalize` (auto-discovered by mkosi)
   but mkosi v26 runs finalize hooks BEFORE the split artifacts are
   staged — the UKI is not yet at `OUTPUTDIR/myosi_<VER>.efi` when
   finalize fires, so the rename silently skipped. 2026.06.07.02
   shipped without UUID stamps for this reason.
4. The `myosi fetch` recipe downloads with `gh release download
   --pattern 'myosi_<VER>_*.{root,verity}.raw.zst'` to handle the
   UUID-stamped names.

## Host-side depmod for kmod sysexts (commit `5e8...`)

mkosi v26 strips `modules.dep` (and friends) from every sysext at
seal time — its de-dup walks the overlay against base-tree by path
presence, not content. The nvidia sysext ships `.ko.xz` files but
no `modules.dep`, so `modprobe nvidia` reports
`Module nvidia not found in directory /lib/modules/<KVER>`.

Fix: `myosi-depmod.service` (runs after `systemd-sysext.service`)
stacks a tmpfs overlay on `/usr/lib/modules/<KVER>/` and runs
`depmod -a`. The regenerated indices live in the tmpfs upper;
modprobe sees the merged view including every merged sysext's
`extra/<name>/` modules.

`/usr/libexec/myosi/sysext-modules-refresh` is the helper script.
`refresh_sysext` in `lib.sh` restarts `myosi-depmod.service` after
every sysext refresh so mid-runtime `myosi extension-enable nvidia`
triggers a fresh depmod without reboot.

## xz options for kmod sysexts (commit `bf...`)

`xz`-recompressed kernel modules need single-block streams (`--threads=1`),
CRC32 checksum, and 1 MiB dict. The kernel's in-tree `xz_dec` cannot
handle multi-block streams or large dicts. Default `xz` settings
produced 9-block CRC64 streams that the kernel rejected with
`decompression failed with status 6` → modprobe `Invalid argument`.

Fix: `mkosi.shared/kmod-build.sh` re-compresses signed `.ko.xz`
files with `xz -q -f --lzma2=dict=1MiB --check=crc32 --threads=1`.
Matches Fedora's stock kmod compression.

## UKI naming bug (`myosi_.efi` instead of `myosi_<VER>.efi`)

`mkosi.conf` had `UnifiedKernelImageFormat=&e_&v` — but mkosi v26
has TWO substitution layers: `%X` config-parse-time and `&X`
delayed. `&v` does not exist in the delayed set; unknown specifiers
expand to empty string. Result: in-image UKI filename was
`myosi_.efi`.

Fix: changed to `UnifiedKernelImageFormat=%i_%v` (config-parse-time
specifiers; `%v` is `IMAGE_VERSION`).

## Operator wrapper + dynamic just dispatch

`/usr/local/bin/myosi` builds `/run/myosi/justfile` per-invocation by
scanning `/usr/share/myosi/just/*.just`. Sysext-provided modules
(e.g., `50-virt.just` from the virt sysext) appear in the dispatch
automatically when the sysext is merged. No `import?` enumeration in
the base image.

## Build-helper layout

All build-time host-side scripts now live under `myosi/scripts/`:

- `scripts/stage-artifacts.sh` — post-`mkosi build` PartitionUUID
  rename. Invoked by both `just build` and CI.
- `scripts/generate-keys.sh` — generates `keys/boot.{key,crt}` and
  `keys/image.{key,crt}`. Run once on dev hosts.
- `scripts/decode-keys.sh` — CI helper that decodes GitHub Actions
  secrets into `keys/`.
- `scripts/sysupdate-manifest.sh` — generates `sysupdate-manifest.json`
  for release artifacts.

The former `ci/` tree-consistency test scripts were removed — they will
be reworked as VM-based tests rather than static file checks.

## Documentation consolidation

The previous `myosi/docs/design.md` and `myosi/install/partition-target.md`
have been merged into this `README.md`. Their full content follows
in the **Design notes** appendix below.

## Image shape: minimal + first-boot expansion (ParticleOS pattern, 2026.06.08+)

The shipped `.raw.zst` is the **minimal layout** (~700 MB compressed):
4 partitions — ESP + root-A + verity-A + verity-sig-A. On first boot,
`systemd-repart` in the initrd reads `/usr/lib/repart.d/` (the
8-partition runtime layout baked in via `ExtraTrees=`) and creates
the missing root-B + verity-B + verity-sig-B + data-luks placeholders,
growing data-luks to fill the target disk.

The exact same `.raw` works as USB live boot AND as installed root —
Lennart Poettering's "Fitting Everything Together" image-based OS
pattern. There is no installer-vs-runtime image split, no
`--profile=` flag, and no two-dir minimal/full confusion.

Layout sources:

| Dir | Consumer | Contains |
|-----|----------|----------|
| `myosi/mkosi.repart/` | mkosi auto-discovery at build time | 4 partition defs (ESP + root-A + verity-A + verity-sig-A) |
| `myosi/mkosi.extra/usr/lib/repart.d/` | shipped in the main image and copied into the initrd sub-image via `ExtraTrees=` | all 8 partition defs (build set + root-B + verity-B + verity-sig-B + data-luks) |

The runtime set's first 4 confs must preserve the build set's `Type=`
and `Label=` identity so first-boot `systemd-repart` matches the
existing partitions and no-ops them; CI fails on identity drift.

Earlier 2026-06-07 iterations of this branch shipped two mkosi profiles
(`full` / `minimal`) selectable via `--profile=`. Once the minimal
qemu validation passed end-to-end, the full profile was retired (same
final state after first boot, just a larger artifact).

## systemd-credentials first-boot configuration (2026.06.07+)

First-boot configuration (hostname, root password, SSH keys, LUKS
passphrase) is delivered through systemd-credentials, not interactive
prompts or kickstart files. Two staging directories ship in every
image:

- `/etc/credstore/` — plaintext credentials, owner-root mode 0600.
- `/etc/credstore.encrypted/` — sealed with `systemd-creds encrypt`
  (TPM2 or host-key). systemd-firstboot and sshd read
  whichever variant is present.

Supported credential names and their consumers are documented in
`/usr/share/myosi/credentials/README.cred.example`. The most useful:

| Credential | Consumer | Effect |
|------------|----------|--------|
| `firstboot.hostname` | systemd-firstboot | overrides baked `/etc/hostname` on first boot |
| `passwd.hashed-password.root` | systemd-firstboot | sets root password (`mkpasswd -m sha512crypt`) |
| `ssh.authorized_keys.root` | sshd (`AuthorizedKeysFile` includes `/run/credentials/...`) | adds keys without service restart |
| `data.key` | initrd `systemd-repart.service` + `sysroot-prep.service` | LUKS2 key file for formatting and unlocking `data-luks` |

Operator helpers ship in `/usr/share/myosi/just/35-credentials.just`:

```bash
# Encrypt + install (default seal is TPM2 if available, host-key otherwise):
echo 'myhost-01' | sudo myosi credential encrypt firstboot.hostname

# Listing and removal:
sudo myosi credential list
sudo myosi credential remove firstboot.hostname
```

ESP-delivered credentials (for the unified USB↔installed flow) work
the same way: drop encrypted `.cred` files into the ESP partition's
`loader/credentials/` directory and systemd-stub will expose them at
boot. Useful for cloning the same `.raw` to multiple hosts with per-
host credentials.

## Portable services support; no confext (2026.06.07+)

myosi ships `systemd-portable` (`portablectl` + `systemd-portabled`)
as the supported mechanism for self-contained service images with
their own `/etc` namespace. Examples: vendored proprietary services
that need a different libc, services that ship internal `/etc`
config and should not bleed into the host overlay.

`/usr/share/myosi/just/45-portables.just` exposes operator helpers:

```bash
sudo myosi portable stage /tmp/myservice.raw     # → /var/lib/portables/
sudo myosi portable inspect myservice.raw        # signatures, units, content
sudo myosi portable attach myservice --enable    # mount + enable units
sudo myosi portable list                         # state
sudo myosi portable detach myservice             # stop + unmount
```

**confext support is rejected.** myosi's `/etc` overlay has exactly
one writable upperdir (`/var/etc`). A confext layer would introduce a
second image-shipped writable `/etc` overlay whose reconciliation
rules with `/var/etc` are not well-defined (which side wins on
conflict, what survives a confext detach, how sysupdate phases
interact with a mid-overlay swap). To enforce the invariant:

- `mkosi.postinst` masks `systemd-confext.service`. CI fails the
  build if the mask is removed.
- The fleet-keys image is deliberately a sysext (not a confext) even
  though it carries only `/etc` files. Its tree merges under the
  `/usr/share/factory/etc` lowerdir, so `/var/etc` still wins, and sysupdate
  replaces the sysext as an atomic unit.

Extensions are **sysexts** (`/usr` files), **portable services** (own
`/etc` namespace), or **operator edits to `/var/etc`** (persistent
per-host config). Nothing else.

---


---

# Design notes (appendix, ex-`docs/design.md`)

The following content is the original design document, preserved as
historical reference and deep technical detail. Internal cross-
references inside this section refer to its own subsections, not the
top-level README structure.


Status: draft v0.1 (initial design) + update log (deltas through 2026-06-04)
Date: 2026-05-30 (original) / 2026-06-04 (current)
Owner: Alan Boglioli

> **Confext layer retired (2026-06-04).** The original design layered a
> second overlay on `/etc` via signed confexts (see §7.2, §10.3, §10.4,
> §9.2). That layer has been removed, and reusable signed configuration
> ships as sysexts under `/usr` instead. The `fleet-keys` bundle is the
> working example — its `authorized_keys` lives at
> `/usr/share/myosi/ssh/authorized_keys.d/` and sshd reads it via an
> `AuthorizedKeysFile` token. Sections that describe `systemd-confext`,
> `/usr/lib/confexts/`, `/var/lib/confexts/`, `/etc/systemd/confext.conf`,
> and per-host confexts are kept for historical context; they describe
> the prior design, not current behavior.
>
> **`/etc` overlay retired (2026-06-20).** The original design also
> overlayfs-mounted `/etc` with `lowerdir=/usr/share/factory/etc` + `upperdir=/var/etc`
> (see §10.6, §7, §14.x). That overlay was retired in favor of `/etc`
> as a real persistent btrfs subvolume on `data-luks`, seeded from
> `/usr/share/factory/etc` via `systemd-tmpfiles`' `C!` directive on first boot.
> Subsequent design-notes subsections (`/etc` overlay at boot, `/etc`
> initrd overlay assembly, overlay copy-up rules, `/var/etc` /
> `/var/.etc-work` references, `myosi-firstboot-relabel.service`,
> `sysroot-prep.service`, the SELinux upperdir pre-seed via `setfattr`)
> describe the prior architecture and remain for historical context.
> The current model is documented at the top of this README (§"Where
> things live", §"The /etc factory-seed footgun", §"Boot path summary",
> §"Why is `/etc` a btrfs subvol instead of an overlay over `/usr/share/factory/etc`?"),
> in `docs/etc-state-architecture-refactor-v2.md`, and in the operative
> initrd units `sysroot-etc.mount` + `myosi-data-attach.service`.

---

## 0. Update log (2026-06-03)

This document captures the initial v0.1 design. The points below
reflect concrete decisions and code that landed after the original
draft. Spot-fixes are intentionally minimal in the body sections;
this section is the authoritative reference for the current state.

### 0.1 Partition layout — final sizes

```
ESP                 vfat   2 GiB        bootloader + UKI (InstancesMax=2); no /boot partition (UKI carries the kernel); FAT mandated by UEFI
root-a              erofs  5 GiB        signed read-only root (slot A, fixed)
root-a-verity       verity 64 MiB       Merkle tree
root-a-verity-sig   cms    16 KiB       PKCS#7 root hash sig
root-b/...                              empty placeholder triple (SplitName=-)
data-luks           luks2+btrfs         baseline 256 MiB; grows to fill disk
```

Slot sizes are pinned because systemd-repart's `--split=yes` pass
recomputes verity offsets if A and B don't match exactly; without
identical sizes the verity-sig partition ends up empty and the build
fails. 5 GiB root holds ~2 GiB today, leaves room to embed
`containers` / `virt` / `firmware` sysexts into the verity-baked
root in future. ESP pinned at 2 GiB (was 1-1.5 GiB range — a range
silently shrinks to the floor on every fresh install because
systemd-repart picks the smallest size that fits CopyFiles=). 2 GiB
gives ~1.4 GiB headroom over the current 2× 256 MiB UKI + bootloader
footprint, absorbs kernel/initramfs growth + an optional 3rd
InstancesMax slot, and stays under the 2.1 GiB FAT32 32-bit-cluster
firmware quirk. See `mkosi.extra/usr/lib/repart.d/00-esp.conf` for the budget. Total
minimum disk ~12 GiB.

### 0.2 Module signing + blacklist policy

- Every `nvidia*.ko` (5 modules per branch) and `zfs.ko` + `spl.ko`
  is signed with `boot.key` via the kernel's `scripts/sign-file`
  inside the buildroot. UKI cmdline ships `module.sig_enforce=1`;
  modules without a valid signature against the `.platform`
  keyring (populated from UEFI db, where boot.crt is enrolled)
  are rejected at load.
- Module blacklist policy is in **one place**: UKI cmdline
  `module_blacklist=nouveau,nova_core,iTCO_wdt,iTCO_vendor_support,sp5100_tco`.
  modprobe.d files
  inside sysexts carry MODULE OPTIONS only. Operators can drop
  ad-hoc overrides into `/etc/modprobe.d/` on the writable
  overlay.

### 0.3 Out-of-tree kmod build helper (NVIDIA + ZFS + future)

`mkosi.shared/kmod-build.sh` provides three primitives reused
across every out-of-tree kmod sysext:

| Helper | Purpose |
|---|---|
| `kmod_exec cmd ...` | Bind-mount /dev + /proc into BUILDROOT, then chroot. NVIDIA's conftest probes and OpenZFS's configure-style probes need real /dev/null + /proc; plain chroot doesn't propagate them and the result is cascading `va_list unknown type` / `dma_is_direct implicit declaration` errors that look like upstream source incompatibilities but are pure sandbox quirks. |
| `kmod_unmount` | Drop /dev + /proc binds before sysext sealing (or strip_to_sysext_layout walks into the host filesystem). |
| `kmod_unmount_all_under "$BUILDROOT"` | Final sweep after `dnf5 remove` — dnf silently re-mounts /proc + /dev into the installroot for rpm scriptlets and doesn't clean up. findmnt-based, skips the buildroot itself so the mkosi-set-up bind doesn't get torched. |

NVIDIA + ZFS already use this. Future ZFS/WireGuard/VirtualBox
sysexts source the same helper.

### 0.4 NVIDIA sysexts — both branches working

- `nvidia` — RPMFusion akmod-nvidia 595.71.05 (open kernel modules,
  Turing+: RTX 16xx/20xx/30xx/40xx/50xx).
- `nvidia-580xx` — RPMFusion akmod-nvidia-580xx 580.159.03
  (proprietary kernel modules, Maxwell/Pascal/Volta — GTX 9xx/10xx,
  Titan V).

Both built end-to-end against kernel 7.0.10-201.fc44. Each ships
~1.8 GiB sealed sysext: 5 kernel modules (nvidia, nvidia-uvm,
nvidia-peermem, nvidia-modeset, nvidia-drm) signed with
boot.key, full xorg-x11-drv-nvidia* userspace, modprobe.d/50-nvidia.conf
with branch-specific options (NVreg_EnableGpuFirmware=1 for
Turing+, =0 for Pascal-and-older which have no GSP).

### 0.5 OpenZFS sysext via upstream tarball

`mkosi.shared/zfs-build.sh` does not depend on the zfsonlinux.org/
fedora packaging (which trails new Fedora releases by months —
verified 2026-06-03, fc40/41/42 → 200, fc43/44 → 404). Build path:

1. Install canonical OpenZFS deps from Fedora repos (per
   openzfs-docs Building ZFS).
2. Download `zfs-${ZFS_VERSION}.tar.gz` from GitHub releases
   directly. Default `ZFS_VERSION=2.4.2` (declares
   Linux-Maximum 7.0 in its META; covers our kernel).
3. `./autogen.sh && ./configure --with-linux=/usr/src/kernels/$KVER`
   + `make srpm-utils srpm-kmod` inside the buildroot via
   `kmod_exec`. Splits into SRPMs (not `make rpm`) because the
   kmod has to cross-build against `$KVER` (not the running
   kernel) via `rpmbuild --rebuild --define "kernels $KVER"`.
4. `rpmbuild --rebuild` kmod + userspace SRPMs.
5. Install all binary RPMs (kmod-zfs-${KVER} + 7 userspace) in
   one dnf5 transaction so the `zfs-kmod=${VERSION}` virtual
   provide resolves atomically.
6. Sign `zfs.ko` + `spl.ko` with boot.key.

`ZFS_BUILD_OPTIONAL=1` makes failures at dep install, fetch,
configure, or rpmbuild non-fatal — CI keeps shipping every other
artifact when OpenZFS hasn't caught up to a new kernel. Bumping
to a newer OpenZFS = bump `ZFS_VERSION` env var, nothing else.

### 0.6 fleet-keys sysext — baked into base for first-boot SSH

`mkosi.images/fleet-keys/` ships SSH `authorized_keys` for
mutual fleet access as a signed **sysext** (originally a confext;
reworked 2026-06-04 — see retirement note at the top). Its payload
lives at `/usr/share/myosi/ssh/authorized_keys.d/user`; sshd
reads it via an `AuthorizedKeysFile` token added in
`mkosi.extra/etc/ssh/sshd_config.d/50-myosi.conf`.

Two locations on a deployed host:

- `/usr/lib/extensions/fleet-keys_VER_ARCH.raw` — copied by base
  `mkosi.postinst` from the build output. Verity-protected,
  read-only, present from first boot. systemd-sysext picks it
  up automatically (the directory is in sysext's default
  search path).
- `/var/lib/extensions/fleet-keys_NEWVER.raw` — written by
  `updatectl update` when a newer rotation lands. sysext
  merges the highest version across all search dirs, so the
  new version takes precedence without a base image rebuild.

Wired via `mkosi.extra/usr/lib/sysupdate.extensions.d/37-fleet-keys.transfer`
+ `fleet-keys.feature` (Enabled=true — every host needs the keys,
not opt-in).

### 0.7 Default credentials — root locked, only user has changeme

`mkosi.extra/etc/shadow`:

```
root:!locked::0:99999:7:::
user:$6$myosiuserinit$...:20603:0:99999:7:::
```

`sysusers.d` has no password column (6 fields:
`TYPE NAME ID GECOS HOME SHELL`). Adding a 7th column triggers
"Trailing garbage." Shipping `/etc/shadow` with the hash is the
only declarative path. Bootstrap on first SSH login (via
fleet-keys publickey):

```
sudo passwd root    # sudo asks for user's pw → "changeme" → set real root pw
passwd              # asks current → "changeme" → set real user pw
```

Image never ships a known root credential.

### 0.8 Prerelease versioning + bare tags everywhere

Tag format: `YYYY.MM.DD.NN` (stable) | `YYYY.MM.DD.NN-rc.N`
(release candidate) | `-beta.N` | `-alpha.N`. No `v` prefix,
no `-manual` suffix. Filenames match the tag verbatim
(`myosi_2026.06.03.01-rc.1.efi`). sysupdate's `@v` interpolation
matches without stripping.

CI workflow `prerelease` input validates `(alpha|beta|rc)\.N`.
GH Release `prerelease: true` flag derived from whether the
suffix was set. sysupdate's `releases/latest/download/` URL
consumes only stable (non-prerelease) releases.

### 0.9 Module signing path inside the build

```sh
SIGN_FILE=/usr/src/kernels/$KVER/scripts/sign-file
install -m 0600 keys/boot.key $BUILDROOT/tmp/sign/boot.key
install -m 0644 keys/boot.crt $BUILDROOT/tmp/sign/boot.crt
# For each *.ko / *.ko.xz / *.ko.zst:
#   decompress → kmod_exec sign-file sha256 boot.key boot.crt → recompress
```

F44 ships zstd-compressed kernel modules; we decompress in
place, sign, recompress with the same filename so the signature
lives at the end of the .ko and survives the zstd round-trip.
Uncompressed `.ko` (OpenZFS path) signs directly.

### 0.10 just build dev / full modes

```
just build         → mkosi -fi build  (incremental, ~3-5 min on warm cache)
just build full    → mkosi -ff build  (clean, ~25-40 min)
```

CI workflow pinned to `mkosi -ff build` so release artifacts are
never contaminated by stale cache state.

### 0.11 Confext layer retired (2026-06-04)

The signed confext mechanism (overlay on `/etc` via
`systemd-confext`, `/var/lib/confexts/`, `/usr/lib/confexts/`,
`sysupdate.confexts.d/`) has been removed. Rationale:

- The base image already runs an `/etc` overlay
  (`/usr/share/factory/etc` lower, `/var/etc` upper). Stacking a second
  confext overlay made copy-up semantics opaque and forced
  `Mutable=yes` (writable upper at
  `/var/lib/extensions.mutable/etc/`) to keep late-boot
  services that write `/etc` working — duplicating the mutable
  upper across two locations.
- The only confext we shipped was `fleet-keys`. Its payload
  (one `authorized_keys` file) trivially fits under `/usr` and
  is reachable via an `AuthorizedKeysFile` token, removing the
  need for the second overlay entirely.

What changed in code:

- `mkosi.images/fleet-keys/` is now `Format=sysext`. Its
  payload moved to `/usr/share/myosi/ssh/authorized_keys.d/`
  and `/usr/lib/extension-release.d/`.
- `mkosi.extra/etc/ssh/sshd_config.d/50-myosi.conf` adds the
  `/usr/share/myosi/ssh/authorized_keys.d/%u` token.
- `mkosi.postinst` no longer enables `systemd-confext.service`
  and bakes `fleet-keys_VER_ARCH.raw` into `/usr/lib/extensions/`
  instead of `/usr/lib/confexts/`.
- Deleted: `mkosi.shared/confext.conf`,
  `mkosi.extra/etc/systemd/confext.conf`,
  `mkosi.extra/usr/libexec/myosi/confext-install`,
  `mkosi.extra/usr/libexec/myosi/confext-remove`,
  `mkosi.extra/usr/lib/sysupdate.confexts.d/`,
  `examples/confexts/`, `scripts/lint-confext.sh`.
- `lib.sh` drops `refresh_confext` / `refresh_extensions`;
  `extension-list`, `extension-disable`, and `update` no
  longer touch the confexts target.
- Two base `/etc` configs moved to `/usr/lib` (NetworkManager
  drop-in, firewalld zone + main conf) since they are
  read-only defaults that don't need to live on the writable
  `/etc` overlay.

Architectural sections of this document that describe
`systemd-confext`, the second `/etc` overlay, and per-host
confexts (§7.2, §9.2, §10.3, §10.4, §15) are kept as a record
of the prior design. They are NOT current behavior.

---

## 1. Overview

`myosi` is a personal atomic, immutable Linux distribution built from scratch using `mkosi` and core systemd primitives. It is a self-contained repository. It coexists with the current `bootc`/`ostree`-based `myos/` and does not modify it. When `myosi` is proven stable across a fleet, it can replace `myos` per-host or fleet-wide.

Conceptually `myosi` is "what would bootc look like if rebuilt directly on top of upstream systemd primitives without ostree, with dm-verity-signed read-only roots, systemd-sysupdate-driven A/B atomic upgrades, and systemd-sysext / systemd-confext layering for hardware variants and per-host identity."

### 1.1 Goals

- **Atomic updates**: a host either runs the full new image or rolls back to the full previous image. No partial state.
- **Immutable root**: `/usr` and `/etc/` (lower layer) are cryptographically signed, mounted read-only, tamper-evident at runtime.
- **Declarative composition**: a host's identity is one base image + one or more signed extensions, all referenced by signed cryptographic hashes.
- **Multi-hardware support**: NVIDIA Turing+ and NVIDIA Pascal/Maxwell/Volta (legacy) coexist as mutually-exclusive sysexts. Hardware-specific bits never leak into the base image.
- **SecureBoot dual-mode**: same image works on hosts with SecureBoot enabled (via shim + MOK) and on hosts with SecureBoot disabled.
- **Manual control over state**: snapshots and rollbacks of `/var` and `/home` are operator-triggered, never automatic.
- **Self-contained**: the entire build, sign, publish, install, update, snapshot, and rollback toolchain lives in this repository, configured by `mkosi.conf`, driven by `just` recipes.

### 1.2 Non-goals (v1)

- Replacing `myos` on production hosts before stability is proven.
- Public distribution / publicly downloadable images (private GitHub repo for now).
- Multi-distro support (mkosi could but we don't — Fedora 44 only).
- An ISO installer (raw image + USB `dd` is the only install path).
- Automatic update scheduling on hosts (manual `systemctl start systemd-sysupdate.service`, or a weekly timer the operator opts into).
- Gaming-specific tooling (`gaming.raw`), host-specific extension images, `tailscale.raw`, `dev.raw` (extra dev tools beyond core CLI). Deferred to post-v1.

### 1.3 Relationship to other parts of the user's setup

| Component | Status |
|-----------|--------|
| `myos/` (current bootc images) | Untouched. Continues working. Eventually superseded by `myosi`. |
| `Containerfile.dev` | Untouched. Distrobox dev environment continues working. |
| Existing hosts | Continue running `myos`. Can opt into `myosi` per-host on the user's schedule. |
| GitHub Actions for `myos` | Untouched. A separate workflow `myosi.yml` is added. |
| GHCR registry `ghcr.io/user/myos-*` | Untouched. `myosi` publishes to GitHub Releases instead of GHCR. |

---

## 2. Glossary

Used throughout this document. Read once.

- **UKI** — Unified Kernel Image. A PE-format `.efi` binary containing kernel + initramfs + kernel command line + os-release + (optional) splash, signed as a single unit for SecureBoot.
- **ESP** — EFI System Partition. FAT32 partition firmware reads to find bootloaders and UKIs.
- **shim** — MS-signed first-stage bootloader (`shimx64.efi`) that validates the next stage against either Microsoft's keys or an enrolled Machine Owner Key (MOK).
- **sd-boot** — `systemd-boot`. UEFI bootloader that auto-discovers UKIs in `/EFI/Linux/` and BLS entries in `/loader/entries/`, manages A/B boot-counting.
- **MOK** — Machine Owner Key. A cert enrolled into the firmware via `mokutil` so shim trusts our signatures.
- **dm-verity** — kernel device-mapper target enforcing block-level read-only integrity over a partition via a Merkle tree. Root hash is signed; any tampered block read returns I/O error.
- **erofs** — Enhanced Read-Only File System. Compact, mmap-friendly, compressed RO Linux filesystem used as the root data layer.
- **sysext** — systemd system extension. A signed `.raw` image (or directory) that gets overlay-merged on `/usr` at boot. Used for optional kernel modules, driver stacks, application bundles.
- **confext** — systemd configuration extension. Same machinery as sysext but targets `/etc` instead of `/usr`.
- **fs-verity** — per-file Merkle tree integrity for ext4/btrfs/f2fs. Used by composefs (not by myosi).
- **systemd-repart** — declarative partition manager. Creates / grows / formats / encrypts partitions on boot from `.conf` files in `/usr/lib/repart.d/`.
- **systemd-sysupdate** — declarative atomic updater. Pulls signed image artifacts from HTTP/OCI/etc., writes to inactive A/B slots, updates boot entries.
- **systemd-cryptenroll** — LUKS keyslot enrollment tool. Adds passphrase, FIDO2, TPM2, or recovery keys to LUKS2 volumes.
- **subvol** (btrfs) — copy-on-write subvolume. Mountable, snapshotable, quota-able unit within a single btrfs filesystem.
- **NoCOW** — `chattr +C` flag on a file or directory: opts out of copy-on-write. Required for large frequently-written files (VM images, databases, container overlay store).
- **MOK / MOK Manager** — UEFI utility that prompts at boot to enroll new keys after `mokutil --import`.

---

## 3. Architecture

### 3.1 Layered boot + integrity chain

```
UEFI firmware                              [validates next stage if SecureBoot on; loads any binary if SecureBoot off]
  ↓
shim (shimx64.efi, MS-signed)              [if SB on: validates against MS keys + MOK; if SB off: skips check]
  ↓
systemd-boot (sd-boot, signed with boot.key, accepted via MOK)
  ↓ selects active UKI from /EFI/Linux/ based on A/B boot counter
UKI (myosi_<version>.efi, signed with boot.key)
  contains: kernel + initramfs + cmdline + os-release
  cmdline includes: roothash=<sha256> rootfstype=erofs rd.systemd.verity=1 \
                    systemd.verity_root_data=PARTLABEL=root-a \
                    systemd.verity_root_hash=PARTLABEL=root-a-verity \
                    systemd.verity_root_options=panic-on-corruption \
                    rootflags=ro mount.usrflags=ro
  ↓
kernel + initramfs (verified as a single PE signature inside the UKI)
  ↓
initramfs (systemd-in-initrd):
  - systemd-repart: on first boot, creates the `data-luks` partition, prompts passphrase,
    formats btrfs, creates subvols. On subsequent boots: no-op.
  - systemd-veritysetup: assembles dm-verity device over root data + hash partitions,
    validates signed root hash against image.crt in kernel keyring.
  - systemd-cryptsetup: unlocks `data-luks` via TPM2 (if enrolled) or passphrase prompt.
  - mounts root via dm-verity (RO).
  - mounts /usr via overlay (lower=verity root /usr, no upper) — strictly read-only.
  - sets up /etc overlay: lower=/usr/share/factory/etc, middle=confext mount, upper=/var/etc.
  - switch_root.
  ↓
systemd PID 1 (in the real root):
  - systemd-sysext.service: scans /etc/extensions/ (symlinks per host) → merges signed sysexts on /usr.
  - systemd-confext.service: scans /etc/confexts/ → merges signed confexts on /etc.
  - normal boot order continues.
```

### 3.2 Trust chain components

| Layer | Signed by | Verified by | What happens on bad sig |
|-------|-----------|-------------|--------------------------|
| shim | Microsoft | UEFI firmware (only if SecureBoot on) | Firmware refuses to load (SB on) or loads anyway (SB off) |
| sd-boot | `boot.key` | shim (via enrolled MOK) | Shim refuses to chain-load (SB on) or loads anyway (SB off) |
| UKI | `boot.key` | sd-boot (via shim's trust) | sd-boot refuses to load (SB on) or loads anyway (SB off) |
| dm-verity root hash | `image.key` (RSA-4096+SHA-384, PKCS#7/CMS) | Kernel keyring (always) | Kernel mount failure → panic in initramfs → sd-boot boot counter trips → rollback to previous slot |
| dm-verity per-block | (root hash, transitive) | Kernel `dm-verity` target | I/O error on tampered block; configurable to panic |
| sysext `.raw` (carries its own dm-verity) | `image.key` | systemd-sysext via kernel keyring | sysext refuses to merge (`SYSEXT_LEVEL` / signature policy) |
| confext `.raw` | `image.key` | systemd-confext (same machinery) | confext refuses to merge |

### 3.3 What works when SecureBoot is disabled

- UEFI firmware loads shim regardless of signature.
- Shim detects `SecureBoot=0` EFI variable and skips its own signature check on the next stage.
- sd-boot, UKI, kernel all load without signature verification.
- **dm-verity still works** — it is a kernel feature, not a firmware feature. Once kernel boots and reads `roothash=` from cmdline, every block read is hash-validated. Block tampering is still caught.
- **What you lose with SB off**: an attacker with physical disk access could overwrite the ESP to point at a UKI containing a different `roothash=`. The disk-integrity boundary moves from "signed by us" to "trust the disk."
- Atomicity, immutability, rollback, /etc persistence — all preserved.

This dual-mode behavior is by design: one image binary, two trust environments, no rebuild required.

### 3.4 Kernel lockdown

UKI command line conditionally sets `lockdown=integrity` when SecureBoot is on (default systemd behavior). When SB is off, lockdown stays off. If a host that has SB off should still enforce lockdown (e.g., production server), the user can append `lockdown=integrity` permanently to the UKI cmdline — this is a build-time decision baked into `mkosi.conf`. v1 does not enforce lockdown when SB is off; this can be revisited.

### 3.3a A/B slot selection (auto-discovery, not PARTLABEL pinning)

The UKI kernel command line does NOT pin `systemd.verity_root_data=PARTLABEL=root-a` or similar. Instead, A/B slot selection relies on:

1. **GPT type GUIDs** — root-a/root-b carry the discoverable-partition-spec type GUID for "Linux root x86-64". The active partition is determined by `PartitionFlags=GPT_FLAG_NO_AUTO` being cleared (active) or set (inactive). systemd-gpt-auto-generator picks the active one at boot.
2. **sd-boot boot-counting** — `loader.conf` carries `BOOT_COUNTING=1`. Each boot attempt decrements a per-UKI counter; three consecutive failed boots flip to the other slot.
3. **systemd-sysupdate** — when a new version lands, it writes to the inactive slot (the one with no-auto flag set), clears that slot's no-auto flag, sets the other slot's no-auto flag. Next reboot picks up the freshly-written slot.

Explicit `PARTLABEL=root-a` would pin to one slot forever, defeating A/B. Earlier drafts of this document overspecified this — corrected here.

The cmdline does set `mount.usrflags=ro` as defense-in-depth: erofs is RO by construction, but the explicit flag makes intent unambiguous and prevents any future accidental remount,rw attempts.

### 3.4a Kernel command line (full)

The UKI bakes a single command-line string. It must cover: dm-verity setup, /usr immutability, security hardening, console behavior, IOMMU for VMs, cgroup v2, and quiet boot. Hardware-specific options (NVIDIA modeset, nouveau blacklist) do **not** belong on the cmdline because the UKI is built once and shared across all hosts; those go in `/usr/lib/modprobe.d/` files shipped inside the relevant sysext.

Baked into `myosi` UKI cmdline:

```
# dm-verity for root
roothash=<computed-at-build>
rootfstype=erofs
rd.systemd.verity=1
systemd.verity_root_data=PARTLABEL=root-a
systemd.verity_root_hash=PARTLABEL=root-a-verity
systemd.verity_root_options=panic-on-corruption,restart-on-corruption

# Root + /usr immutability
rootflags=ro
mount.usrflags=ro

# Initramfs storage
rd.luks.options=tpm2-device=auto,discard
rd.luks.timeout=120

# Security hardening
lockdown=integrity                # ignored when SB off; enforced when SB on
module.sig_enforce=1              # kernel modules must be signed
init_on_alloc=1                   # zero heap on alloc
init_on_free=1                    # zero heap on free
slab_nomerge                      # separate slab caches per type
page_alloc.shuffle=1              # randomize page allocator freelist
randomize_kstack_offset=on        # randomize kernel stack
vsyscall=none                     # disable legacy vsyscall
debugfs=off                       # no debugfs (info leak surface)
mitigations=auto,nosmt            # full CPU vuln mitigations including SMT disable
selinux=1                         # keep SELinux loaded; enforcing mode is policy decision
enforcing=1                       # SELinux enforcing by default

# Cgroup + container support
systemd.unified_cgroup_hierarchy=1
cgroup_no_v1=all

# IOMMU (for VM passthrough and PCIe device isolation)
iommu=pt                          # passthrough mode
intel_iommu=on                    # ignored on AMD CPUs
amd_iommu=on                      # ignored on Intel CPUs

# Hugepages: avoid latency spikes
transparent_hugepage=madvise

# Console behavior
quiet
loglevel=3
rd.udev.log_level=3
console=ttyS0,115200n8            # serial for headless / debug
console=tty0                       # primary console for laptop display and initrd prompts

# Audit (off by default; on in headless server confext if needed)
audit=0
```

Result: one string applied via mkosi `KernelCommandLine=` setting, baked into the signed UKI. Same cmdline boots every host, regardless of hardware. Per-host cmdline tweaks (rare) go through a re-built UKI shipped via a host-specific UKI release path; not v1.

Hardware/sysext-specific kernel knobs handled via `/usr/lib/modprobe.d/` files shipped inside the sysext:

`nvidia.raw`/`nvidia-580xx.raw` ships:

`/usr/lib/modprobe.d/50-nouveau-blacklist.conf`:
```
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
```

`/usr/lib/modprobe.d/50-nvidia.conf`:
```
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_EnableGpuFirmware=1
options nvidia-drm modeset=1 fbdev=1
```

`virt.raw` ships:

`/usr/lib/modprobe.d/50-kvm.conf`:
```
options kvm_intel nested=1 ept=1
options kvm_amd nested=1
options vhost_net experimental_zcopytx=1
```

This way the UKI does not encode hardware specifics; activating the relevant sysext brings the knobs along with the userspace drivers, atomically.

### 3.5 TPM2 and PCR binding

When the operator enrolls TPM2 post-install with `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14`, the LUKS volume gets a TPM2 keyslot bound to stable boot-policy inputs:

- **PCR 7** = SecureBoot policy state. Toggling SB on/off invalidates the binding.
- **PCR 14** = shim/MOK policy state. MOK or SecureBoot trust-anchor changes invalidate the binding.

This is acceptable because:
- The passphrase keyslot should exist as fallback before wiping the bootstrap key-file slot. TPM2 unlock failure prompts for passphrase.
- PCR 11 is intentionally avoided because it changes on every UKI update and would force re-enrollment after normal upgrades.

---

## 4. Distro + base image

### 4.1 Base distro

Fedora 44. Same as `myos`. Reasons:

- Direct knowledge transfer from existing `myos` profiles and the user's kernel-locking work.
- `dnf5` is mature on Fedora 44, with built-in `versionlock` and `copr` subcommands.
- RPMFusion package availability for NVIDIA, ffmpeg, codecs.
- `mkosi` has first-class Fedora support including dnf5 backend.
- Kernel 6.18 / 6.19 work the user has already done on overlayfs and NVIDIA branch splits carries over.

### 4.2 Base packages

The base image stays minimal (target ≤1.5 GiB compressed erofs) so it fits comfortably under GitHub Releases' 2 GiB per-file cap with room to grow.

```
# Init + boot
systemd
systemd-boot-unsigned     # signed at build time
mokutil                   # MOK enrollment for signed root/sysext/confext validation
systemd-container         # for systemd-nspawn
systemd-resolved          # DNS resolver (NetworkManager integrates with it)
systemd-cryptsetup
systemd-repart
systemd-sysext
systemd-sysupdate
kernel
kernel-modules
kernel-modules-extra
kernel-modules-core
dracut
linux-firmware-whence     # license metadata only; full firmware in firmware.raw sysext

# Storage
btrfs-progs
duperemove
compsize
util-linux
iproute                   # ip(8) for network diagnostics
iputils                   # ping(8) for network diagnostics
hostname                  # hostname(1) for basic host inspection
e2fsprogs                 # mkfs.ext4 for ESP-adjacent uses
dosfstools                # mkfs.vfat
cryptsetup
veritysetup
tpm2-tools
tpm2-tss

# Network
NetworkManager
NetworkManager-wifi
firewalld
openssh-server
openssh-clients
wireless-regdb            # base regulatory db; full firmware in firmware.raw
iw

# Containers + container tooling
podman
podman-compose
distrobox
skopeo

# Core CLI (matches existing myos core.sh ethos)
fish
bash
neovim
git
git-delta
just
jq
ripgrep
fd-find
fzf
bat
eza
zoxide
gnupg2
pinentry-tty
curl
wget
rsync
tar
unzip
xz
zstd
bzip2
gzip
file
findutils
coreutils
procps-ng
libatomic
glibc-langpack-en

# Optional but cheap
zram-generator-defaults

# Build pulls these COPR packages
# COPR atim/starship   → starship
# COPR alternateved/eza → eza (more recent than Fedora's)
# Gemfury rsteube      → carapace-bin (isolated copy)
```

Build matches `myos`'s established patterns: COPR repos are disabled after package install (no COPR repo enabled in shipped image), and `copr_install_batch` + `copr_install_isolated` + `fury_install_isolated` helpers from `myos/lib/functions.sh` are reused. The reuse happens via a build-time copy from `../myos/lib/functions.sh` into `mkosi.extra/usr/share/myosi/lib/functions.sh` — see §15.

### 4.3 What is *not* in the base

These belong in sysexts and are absent from the base image:

- `flatpak` → `desktop.raw`
- All Wayland compositors, Wayland tools, GUI fonts → `desktop.raw`
- Pipewire, Wireplumber → `desktop.raw`
- NVIDIA drivers → `nvidia.raw` or `nvidia-580xx.raw`
- Wireless / SoC firmware blobs → `firmware.raw`
- qemu, libvirt, virt-manager, swtpm, edk2-ovmf, incus → `virt.raw`
- ffmpeg, codecs (RPMFusion non-free) → `desktop.raw` (where they're actually used)

This separation is the central design move: the base image is the same across every host. Hardware and use-case variation lives in sysexts. Per-host identity lives in confexts.

---

## 5. Image catalog (v1)

| Image | Type | Format | Approx size | Targets |
|-------|------|--------|-------------|---------|
| `myosi` | disk image | GPT + erofs root + verity + LUKS placeholder | ~1.2 GiB compressed | Every host |
| `desktop.raw` | sysext | erofs + dm-verity sig | ~700 MiB | Hosts with a graphical session |
| `nvidia.raw` | sysext | erofs + dm-verity sig | ~1.8 GiB | Turing+ GPUs (RTX 16xx/20xx/30xx/40xx/50xx). 5 signed kmods + CUDA userspace. |
| `nvidia-580xx.raw` | sysext | erofs + dm-verity sig | ~1.9 GiB | Maxwell/Pascal/Volta GPUs (GTX 9xx/10xx, Titan V). 5 signed kmods + CUDA userspace. |
| `zfs.raw` | sysext | erofs + dm-verity sig | ~500 MiB | Hosts with ZFS pools. Signed `zfs.ko` + `spl.ko` + zfs/zpool/zed userspace. |
| `fleet-keys.raw` | sysext | erofs + dm-verity sig | ~1 MiB | SSH `authorized_keys` for fleet-wide mutual access. Ships its payload at `/usr/share/myosi/ssh/authorized_keys.d/user`; sshd reads it via `AuthorizedKeysFile`. Baked into base at `/usr/lib/extensions/`; rotated via sysupdate to `/var/lib/extensions/`. |
| `firmware.raw` | sysext | erofs + dm-verity sig | ~600 MiB | Hosts needing wireless / SoC firmware |
| `virt.raw` | sysext | erofs + dm-verity sig | ~800 MiB | Hosts running VMs or system containers |
| `<name>.confext.raw` | confext | erofs + dm-verity sig | ~16 KiB | Optional — reusable signed config overlay (examples under `examples/confexts/`) |

### 5.1 `myosi`

Disk image (`mkosi Format=disk`). GPT-partitioned. Contains:

- ESP (`/EFI/`) with shim, sd-boot, and one UKI.
- root-a partition with erofs payload + dm-verity hash + signature.
- root-b empty (filled by sysupdate's first update).
- placeholder for data-luks (created at first boot by repart).

Built by `mkosi.conf` at `myosi/mkosi.conf`. See §6 for partition spec, §15 for full repo layout.

### 5.2 `desktop.raw` sysext

Packages installed inside the sysext's `/usr` namespace:

```
# Compositor + bar + launcher
niri (COPR yalter/niri)
waybar
fuzzel
dunst
swaylock

# Display server bits
xdg-desktop-portal
xdg-desktop-portal-gnome
xorg-x11-server-Xwayland
xwayland-satellite (COPR ulysg/xwayland-satellite)

# Graphics stack
mesa-dri-drivers
mesa-vulkan-drivers
vulkan-loader
libxkbcommon

# Audio
pipewire
pipewire-alsa
pipewire-jack-audio-connection-kit
pipewire-pulseaudio
wireplumber

# Input + screen utilities
grim
slurp
wl-clipboard
brightnessctl

# Bluetooth + power
bluez
blueman
gnome-keyring
polkit
power-profiles-daemon
network-manager-applet

# Terminal
ghostty (COPR scottames/ghostty)

# Codecs (RPMFusion non-free)
ffmpeg

# Fonts
fira-code-fonts
jetbrains-mono-fonts
google-noto-emoji-fonts
monaspace-fonts (COPR zawertun/monaspace or GitHub release fallback)

# Flatpak (desktop-coupled)
flatpak
```

Services enabled inside sysext (effective when merged):

- `power-profiles-daemon.service`
- `flatpak-setup-flathub.service` (custom unit shipped in sysext; sets up flathub remote on first activation)

Shipped configs:

- `glib-compile-schemas /usr/share/glib-2.0/schemas/` runs in mkosi postinst so dconf defaults work after merge.

### 5.3 `nvidia.raw` sysext

Packages:

```
akmod-nvidia                  # current branch (Turing+, presently 595.x on F44 RPMFusion)
xorg-x11-drv-nvidia
xorg-x11-drv-nvidia-cuda
xorg-x11-drv-nvidia-libs
xorg-x11-drv-nvidia-power
nvidia-modprobe
nvidia-persistenced
nvidia-container-toolkit
libnvidia-container1
libnvidia-container-tools
```

Kernel module strategy: the akmod must build against the kernel shipped in the base image. The sysext build job:

1. Pins to the same kernel version as `myosi` (read from `myosi`'s build manifest).
2. Builds akmod inside a chroot matching that kernel.
3. Bakes the resulting `kmod-nvidia-<version>.rpm` into the sysext, plus the userspace.

The sysext's `extension-release.<name>` declares `SYSEXT_IMAGE_VERSION` equal to the kernel ABI it was built for. Activation on a host with a different kernel ABI is refused by systemd-sysext.

Implication for updates: when the base image bumps the kernel, `nvidia.raw` must be rebuilt. CI handles this by detecting kernel changes in the base image build and triggering the NVIDIA sysext rebuild.

### 5.4 `nvidia-580xx.raw` sysext

Same shape as `nvidia.raw`, packages:

```
akmod-nvidia-580xx
xorg-x11-drv-nvidia-580xx
xorg-x11-drv-nvidia-580xx-cuda
xorg-x11-drv-nvidia-580xx-libs
xorg-x11-drv-nvidia-580xx-power
nvidia-modprobe
nvidia-persistenced
nvidia-container-toolkit
libnvidia-container1
libnvidia-container-tools
```

Build-time critical detail (carried over from `project_nvidia_580xx_open_default.md`): pass `_without_kmod_nvidia_detect 1` to akmod build to avoid lspci-based auto-detection picking the wrong variant inside the build container.

**Mutually exclusive with `nvidia.raw`.** Their `/usr` payloads overlap (`/usr/bin/nvidia-smi`, `/usr/lib/modules/.../nvidia.ko`, etc.). Activating both on the same host = boot failure. Enforcement: CI lints each host's confext to symlink at most one. Runtime: systemd-sysext refuses overlap and emits a clear error.

### 5.5 `firmware.raw` sysext

Packages:

```
linux-firmware
intel-gpu-firmware
amd-gpu-firmware
nvidia-gpu-firmware
iwlwifi-mvm-firmware
iwlwifi-dvm-firmware
iwlegacy-firmware
atheros-firmware
brcmfmac-firmware
mt7xxx-firmware
realtek-firmware
wireless-regdb
```


### 5.6 `virt.raw` sysext

Packages:

```
# qemu stack
qemu-kvm
qemu-system-x86
qemu-system-x86-core
qemu-img
qemu-char-spice
qemu-device-display-virtio-gpu
qemu-device-display-virtio-vga
qemu-device-usb-host
qemu-block-curl
qemu-block-rbd
edk2-ovmf

# libvirt
libvirt-daemon
libvirt-daemon-driver-qemu
libvirt-daemon-driver-network
libvirt-daemon-driver-storage-core
libvirt-daemon-driver-storage-disk
libvirt-daemon-driver-storage-iscsi
libvirt-daemon-driver-storage-logical
libvirt-daemon-driver-nwfilter
libvirt-daemon-driver-interface
libvirt-daemon-config-network
libvirt-client
virt-install

# UI tools (desktop hosts will combine with desktop.raw)
virt-manager
virt-viewer

# TPM emulation (matches existing myos swtpm.conf tmpfile)
swtpm
swtpm-tools

# Shared folders
virtiofsd

# SPICE guest support
spice-server
spice-protocol

# CD image generation (cloud-init seed isos, ad-hoc isos)
genisoimage

# System containers (Incus)
incus (COPR ganto/lxc4)
incus-tools
lxc
lxcfs
```

Services enabled:

- `libvirtd.socket` (socket-activated; daemon runs only when needed)
- `virtlogd.socket`
- `virtlockd.socket`
- `incus.socket`
- `incus-startup.service`

Users / groups (declared in sysext sysusers.d):

- group `libvirt`, group `kvm`, group `incus`, group `incus-admin`
- `user` added to `libvirt`, `kvm`, `incus-admin` (delta applied by sysext sysusers.d)

NetworkManager interaction: libvirt creates `virbr0`, incus creates `incusbr0`. NetworkManager configured (via base) to ignore these bridges.

### 5.7 Per-host `<host>.confext.raw`

One per known host. Contents (filesystem layout inside the confext):

```
etc/
├── hostname                              # plaintext host name
├── machine-info                          # PRETTY_HOSTNAME, ICON_NAME, etc.
├── extensions/                           # activation set: symlinks to /var/lib/extensions/*.raw
│   ├── desktop.raw -> /var/lib/extensions/desktop.raw
│   ├── nvidia.raw -> /var/lib/extensions/nvidia.raw         (or nvidia-580xx.raw, never both)
│   ├── firmware.raw -> /var/lib/extensions/firmware.raw
│   └── virt.raw -> /var/lib/extensions/virt.raw              (optional)
├── shadow                                # per-host password override (Way 1)
├── ssh/
│   └── authorized_keys.d/
│       └── user                     # this host's allowed pubkeys
├── NetworkManager/
│   └── system-connections/
│       └── <host-specific-profiles>.nmconnection
├── extension-release.d/
│   └── extension-release.<host>          # mandatory for confext to be accepted
└── myosi/
    └── host.conf                         # host metadata: hardware notes, install timestamp
```

`/etc/extensions/` symlinks are the load-bearing piece. They determine which sysexts merge on this host. systemd-sysext only merges sysexts symlinked here (when `/etc/extensions/` is non-empty, it acts as a whitelist; absence = merge all in `/var/lib/extensions/`).

Build sources for confexts live at `myosi/hosts/<name>/`. See §15 for full layout.

CI lint (`myosi/scripts/lint-confext.sh`) checks each confext for:

- Exactly zero or one `nvidia*.raw` symlink.
- `/etc/extension-release.d/extension-release.<name>` present.
- `/etc/hostname` non-empty.
- No plaintext `shadow` committed to git (must be `age`-encrypted or absent — see §11.4).

---

## 6. Partition layout (systemd-repart)

Build-time partition definitions live at `myosi/mkosi.repart/` and are auto-discovered by mkosi when composing the shipped `.raw`. Runtime/first-boot definitions live at `myosi/mkosi.extra/usr/lib/repart.d/`; they ship in the deployed root and are copied into the initrd at `/usr/lib/repart.d/` so initrd `systemd-repart.service` can create missing partitions before `/var` is mounted.

### 6.1 Layout overview

| # | Partition | Type GUID | Format | Size | Encrypted | Purpose |
|---|-----------|-----------|--------|------|-----------|---------|
| 1 | `esp` | EFI System | FAT32 | 2 GiB | no | shim, sd-boot, UKIs (kernel embedded in each UKI; no separate /boot) |
| 2 | `root-a` | linux-root-x86-64 | erofs | 4 GiB | no (dm-verity) | active root data slot A |
| 3 | `root-a-verity` | linux-root-x86-64-verity | raw | 32 MiB | no | verity hash tree for slot A |
| 4 | `root-a-verity-sig` | linux-root-x86-64-verity-sig | raw | 4 KiB | no | signature for slot A root hash |
| 5 | `root-b` | linux-root-x86-64 | (raw) | 4 GiB | no (dm-verity) | inactive slot B; populated by sysupdate |
| 6 | `root-b-verity` | linux-root-x86-64-verity | raw | 32 MiB | no | verity hash tree for slot B |
| 7 | `root-b-verity-sig` | linux-root-x86-64-verity-sig | raw | 4 KiB | no | signature for slot B root hash |
| 8 | `data-luks` | linux-var | LUKS2 → btrfs | rest of disk | yes | mutable data volume containing `/var` plus the `/home` subvolume |

`root-b*` partitions are created empty by the runtime repart set so sysupdate has somewhere to write the next update without having to repartition later.

### 6.2 Concrete `.conf` files

`myosi/mkosi.extra/usr/lib/repart.d/00-esp.conf`:

```ini
[Partition]
Type=esp
Format=vfat
SizeMinBytes=2G
SizeMaxBytes=2G
CopyFiles=/efi:/
CopyFiles=/boot/EFI/Linux:/EFI/Linux
```

`myosi/mkosi.extra/usr/lib/repart.d/12-root-a.conf`:

```ini
[Partition]
Label=root-a
Type=root
Verity=data
VerityMatchKey=root
SplitName=root
CopyBlocks=auto
SizeMinBytes=5G
SizeMaxBytes=20G
Weight=200
```

`myosi/mkosi.extra/usr/lib/repart.d/11-root-a-verity.conf`:

```ini
[Partition]
Type=root-verity
Label=root-a-verity
Verity=hash
VerityMatchKey=root
SplitName=verity
SizeMinBytes=400M
SizeMaxBytes=400M
```

`myosi/mkosi.extra/usr/lib/repart.d/10-root-a-verity-sig.conf`:

```ini
[Partition]
Type=root-verity-sig
Label=root-a-verity-sig
Verity=signature
VerityMatchKey=root
SplitName=verity-sig
```

`myosi/mkosi.extra/usr/lib/repart.d/22-root-b.conf`:

```ini
[Partition]
Type=root
Label=_empty
NoAuto=1
SplitName=-
SizeMinBytes=5G
SizeMaxBytes=20G
Weight=200
```

`myosi/mkosi.extra/usr/lib/repart.d/21-root-b-verity.conf`:

```ini
[Partition]
Type=root-verity
Label=_empty
NoAuto=1
SplitName=-
SizeMinBytes=400M
SizeMaxBytes=400M
```

`myosi/mkosi.extra/usr/lib/repart.d/20-root-b-verity-sig.conf`:

```ini
[Partition]
Type=root-verity-sig
Label=_empty
NoAuto=1
SplitName=-
```

`myosi/mkosi.extra/usr/lib/repart.d/90-data.conf`:

```ini
[Partition]
Type=var
Label=data-luks
SizeMinBytes=256M
FactoryReset=yes
Encrypt=key-file
KeyFile=/usr/share/myosi/keys/data.key
Format=btrfs
Subvolumes=/var
Subvolumes=/home
Subvolumes=/srv
DefaultSubvolume=/var
MakeDirectories=/var
MakeDirectories=/home
MakeDirectories=/srv
MakeDirectories=/var/etc
MakeDirectories=/var/.etc-work
MakeDirectories=/var/etc/ssh
MakeDirectories=/var/roothome
```

Notes:

- The outer GPT partition is a DPS `Type=var` LUKS container. `systemd-repart` formats it as LUKS2 with the bootstrap key file, formats the inside as btrfs, creates `/var`, `/home`, and `/srv` subvolumes, makes `/var` the default subvolume, and pre-creates the `/etc` overlay directories under `/var`.
- `FactoryReset=yes` ensures that on first boot, the partition is wiped and recreated. Subsequent boots skip recreation and only growth is attempted.
- `No SizeMaxBytes` lets the data partition absorb remaining free space.

### 6.3 Early `/var` unlock and mount

Static sealed-root `/etc/fstab` and `/etc/crypttab` are intentionally not shipped. The sealed erofs `/etc` is wiped after its factory contents are snapshotted to `/usr/share/factory/etc`; local persistent overrides live in the `/var/etc` overlay upperdir.

The initrd boot chain is:

1. `systemd-repart.service` reads `/usr/lib/repart.d/*.conf` from the initrd and creates or grows missing partitions.
2. `sysroot-prep.service` runs `/usr/libexec/myosi/sysroot-prep`.
3. The helper finds the mounted `/sysroot` source, walks dm slaves to the real root GPT partition, resolves the parent disk, and selects exactly one DPS `Type=var` partition on that same disk.
4. The helper unlocks that partition as `/dev/mapper/data` with `/usr/share/myosi/keys/data.key` and `tpm2-device=auto,discard`, unlocks present `data-N` pool members, runs `btrfs device scan`, and mounts `subvol=/var` from `/dev/mapper/data` at `/sysroot/var`.
5. `sysroot-etc.mount` overlays `/sysroot/etc` with `lowerdir=/sysroot/usr/share/factory/etc`, `upperdir=/sysroot/var/etc`, and `workdir=/sysroot/var/.etc-work`.

The btrfs top-level is not normally mounted. `/var`, `/home`, and `/srv` are sibling subvolumes. `/home` and `/srv` are mounted post-switch by `home.mount` and `srv.mount` using `subvol=/home` and `subvol=/srv`. User directories under `/home` are regular directories created by systemd-tmpfiles. `/root → var/roothome` resolves to a plain directory inside `/var`.

NoCOW is declared by tmpfiles `h ... +C` entries for high-write paths such as `/var/log`, `/var/lib/containers`, `/var/lib/libvirt`, and `/var/lib/incus`.

### 6.4 Secondary LUKS — initrd label scan

**Architecture:** secondary disks that are members of the data btrfs pool are not enumerated in any config file. `sysroot-prep` scans present LUKS devices in the initrd, selects labels matching `data-[0-9]+`, unlocks them as `/dev/mapper/data-N`, runs `btrfs device scan`, and then mounts `/sysroot/var` from `/dev/mapper/data`.

There is intentionally no runtime udev rule or template service. Early `/var` is a hard boot dependency, so all required pool members must be present and unlocked before `sysroot-etc.mount` forms the `/etc` overlay. Optional encrypted disks that do not gate `/var` belong in operator-managed `/var/etc/crypttab` or explicit post-boot units.

**Operator workflow to add a disk:**

```bash
SECONDARY=/dev/disk/by-id/nvme-…    # the new disk, full-disk LUKS

# Wipe any pre-existing FS signatures
sudo wipefs -a "$SECONDARY"

# luksFormat — --label must match data-<digit>+ for sysroot-prep to scan.
# data-1, data-2, etc. --force-password bypasses libpwquality
# dictionary check (cracklib-dicts is not in the base image).
sudo cryptsetup luksFormat --type luks2 --label data-1 \
    --force-password "$SECONDARY"
sudo cryptsetup luksOpen "$SECONDARY" data-1

# Mandatory: enroll TPM2 with PCR 7+14 (same policy as primary).
# Without this every boot prompts for the secondary's passphrase
# on the console; on a headless / unattended host that just hangs.
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 \
    "$SECONDARY"

# Add to the /var btrfs pool (the typical use case)
sudo btrfs device add /dev/mapper/data-1 /var
sudo btrfs balance start \
    -dconvert=single -mconvert=raid1 -sconvert=raid1 /var

sudo reboot
```

**At next boot:** `sysroot-prep` scans present LUKS devices, unlocks labels matching `data-[0-9]+`, runs `btrfs device scan`, and mounts the multi-device pool at `/sysroot/var`.

**Single-disk hosts pay zero cost** — no LUKS2 disk with matching label exists, the initrd scan skips immediately, and there are no pending crypttab jobs in systemctl. Compare with pre-declared crypttab slots which clutter `systemctl list-jobs` with 12 pending entries (slot units + their device dependencies) on every boot.

**Failure semantics — all-or-nothing on the pool:** if unlock fails for any matched disk, `/dev/mapper/data-N` is missing and btrfs refuses to mount the multi-device pool because myosi does not use `-o degraded`. `sysroot-prep.service` fails, so boot drops to emergency before the `/etc` overlay is formed. This is intentional: a partial pool would mount corrupted data. Operator must repair (enroll TPM, fix PCR drift, restore the missing disk) before next boot.

**Why NOT pre-declared crypttab slots, `/etc/crypttab.d/` drop-ins, ESP merge, signed UKI addons, systemd.extra-unit credentials, custom systemd generators, per-host UKI rebuilds, runtime udev, or LVM/md concat under a single LUKS?** All considered. Short version: each alternative either fails technically, adds ordering risk, or adds significant operator burden for no real gain. The direct initrd scan makes early boot deterministic and keeps one automatic unlock path.

**When `/var/etc/crypttab` edits ARE legitimate** (rare): post-boot-mount volumes that don't gate `/var` itself — e.g. a USB stick mounted at `/mnt/external-archive` under user control, an opt-in encrypted home subvolume mounted after multi-user.target. The overlay write to `/var/etc/crypttab` works for these because the initrd doesn't read them; main-system `daemon-reload` after the edit instantiates the unit. For anything the initrd MUST unlock to mount `/var`, label the disk `data-N` and let `sysroot-prep` handle it.

### 6.5 LUKS-by-default mutable state

`/var`, `/home`, and `/srv` are encrypted by default. On first boot, initrd `systemd-repart.service` formats `data-luks` as LUKS2 using `/usr/share/myosi/keys/data.key`, creates btrfs, creates the three subvolumes, and pre-creates the `/etc` overlay directories under `/var`. Every boot, `sysroot-prep.service` unlocks it as `/dev/mapper/data` and mounts `subvol=/var` at `/sysroot/var` early so the writable `/etc` overlay has persistent storage before `switch_root`.

TPM2 and passphrase unlock methods are optional and can be enrolled later with `systemd-cryptenroll`. The key-file slot is the old-hardware fallback path and keeps boot non-interactive on systems without TPM2.

### 6.6 First-boot disk growth pipeline

The shipped image carries a tiny 256 MiB `data-luks` partition (`mkosi.extra/usr/lib/repart.d/90-data.conf` `SizeMinBytes=256M`). The full disk image is therefore small and the actual capacity is reclaimed on first boot in the initrd:

1. `systemd-repart.service` runs after `sysroot.mount`, reads `/usr/lib/repart.d/*.conf` from the initrd, creates missing root-B/verity-B/data partitions, and grows `data-luks` to fill remaining space.
2. repart formats `data-luks` as LUKS2 with `/usr/share/myosi/keys/data.key`, formats the inside as btrfs, creates `/var`, `/home`, and `/srv`, and pre-creates `/var/etc`, `/var/.etc-work`, `/var/etc/ssh`, and `/var/roothome`.
3. `sysroot-prep.service` unlocks `/dev/mapper/data`, scans btrfs, and mounts `/sysroot/var`; the btrfs filesystem then sees the grown mapper before switch-root.

---

## 7. Root filesystem and `/etc` layering

### 7.1 Root mount

After dm-verity assembles, the kernel mounts the erofs root partition read-only at `/sysroot`, then `switch_root` makes it `/`. Root is RO, signed, and cannot be written to under any circumstance (verity panics on tamper).

`/var` mounts on top from the LUKS btrfs (subvol `/var`).
`/home` mounts on top from the same LUKS btrfs (subvol `/home`, with user directories like `user/` as regular dirs inside it).

### 7.2 `/etc` layering

`/etc` is an overlayfs mount assembled in initramfs. Stack bottom → top:

1. **Lower (RO):** `/usr/share/factory/etc` from the erofs root partition. `mkosi.postinst` snapshots the image-shipped `/etc` baseline here after package installation.
2. **Middle (RO):** confext mount. Per-host bundle merged into `/etc`. May ship overrides for image defaults; overlayfs file resolution returns the topmost matching path.
3. **Upper (RW):** `/var/etc`, persistent on the encrypted btrfs.

Resolution semantics:

- Read a file: overlayfs returns the topmost copy. Upper > confext > lower.
- Write a file: copy-up triggered. Modified copy lands in upper.
- Delete a file: whiteout marker in upper.
- Confext refresh during runtime: middle layer remounted. Upper unaffected (it's read-write user data).
- Image upgrade: lower changes. Upper persists. Existing upper files mask new lower files.

**Drift behavior over time:** state accumulates in TWO upper-layer directories (see §10.6 for why):
- `/var/etc` — early-boot writes (sysusers, machine-id, anything before `systemd-confext.service` activates)
- `/var/lib/extensions.mutable/etc/` — late-boot writes (sshd-keygen, NetworkManager state, user edits)

To return to image defaults: boot rescue, mount `/var`, `rm -rf /var/etc/* /var/lib/extensions.mutable/etc/*`, reboot. Document as "factory-reset /etc" procedure (§14.7).

### 7.3 Image-shipped `/etc` defaults

Lives in repo at `myosi/mkosi.extra/etc/`. Files ship directly to `/etc` in the buildroot — repo source `mkosi.extra/etc/X` lands at `/etc/X` post-package-install. mkosi.postinst then snapshots the whole `/etc` to `/usr/share/factory/etc` as the overlay lowerdir (see §10.6). Earlier drafts considered shipping repo source via `mkosi.extra/usr/share/factory/etc/` directly and skipping the snapshot, but that path requires bootc-style 3-way merge to surface at `/etc` at install time; myosi uses sysupdate, not bootc-install, so files dropped at `mkosi.extra/usr/share/factory/etc/` would not reach `/etc` on the running system. The snapshot-from-`/etc` approach keeps source paths in repo identical to runtime paths on the host, which is easier to reason about.

Contents (non-exhaustive):

- `hostname` — placeholder `myosi`. Confext overrides per host.
- `locale.conf` — `LANG=en_US.UTF-8`.
- `vconsole.conf` — `KEYMAP=us`.
- `os-release` — myosi metadata (`ID=myosi`, `ID_LIKE=fedora`).
- `shadow` — root + user hashes baked at build time (see §8.1).
- `subuid`, `subgid` — rootless podman ranges (user: 100000:65536, root: 1000000:65536).
- `ssh/sshd_config.d/50-myosi.conf` — see §8.4.
- `ssh/authorized_keys.d/user` — operator-managed ed25519 pubkeys.
- `sudoers.d/wheel` — see §8.3.
- `systemd/sysext.conf`, `systemd/confext.conf` — see §10.4.
- `systemd/zram-generator.conf` — zstd zram, 16 GiB cap, always on.
- `systemd/system.conf.d/10-timeout.conf` — `DefaultTimeoutStopSec=15s`.
- `crypttab` — see §6.3.
- `fstab` — see §6.2.
- `dnf/dnf5.conf` — `installonly_limit=2`, `clean_requirements_on_remove=True`.
- `NetworkManager/conf.d/00-myosi.conf` — `unmanaged-devices=interface-name:virbr*,incusbr*,docker*,podman*`.
- `firewalld/firewalld.conf`, `firewalld/zones/public.xml` — SSH-only public zone.
- `containers/containers.conf` — crun runtime, sqlite backend, zstd:chunked, pasta rootless net.
- `security/limits.d/memlock.conf` — 2 GiB memlock.
- `profile.d/editor.sh`, `profile.d/gpg.sh` — `EDITOR=nvim`, `GPG_TTY`.

The verity-protected root is mounted RO at boot. The `initrd` cpio sub-image sets up an overlay on `/etc` before `switch_root` so runtime writes (sysusers, machine-id, sshd-keygen) land in `/var/etc` on LUKS+btrfs.

---

## 8. Identity and credentials

### 8.0 Hostname policy

Host identity is local by default. Operators set hostname with `hostnamectl`, and the writable `/etc` overlay preserves it in `/var/etc` or the confext mutable upper. Per-host confexts are optional advanced artifacts, not the normal installation path.

### 8.1 Initial user

Single user `user`, UID 1000, primary group `user`, member of `wheel` + `video` + `render` + `input` + `kvm` + `libvirt` + `incus-admin`. Declared in `myosi/mkosi.extra/usr/lib/sysusers.d/user.conf`:

```
u user 1000 "Example User" /home/user /usr/bin/fish
g wheel 10 -
m user wheel
m user video
m user render
m user input
m user kvm
m user libvirt
m user incus-admin
```

Note: NO inline password field on the `u` line. The hash is shipped separately in `/etc/shadow` (see §8.2). This avoids two pitfalls of the inline-password approach:

1. systemd-sysusers `u` type silently rejects UIDs outside the system range (< 1000) and auto-allocates the next free system UID — so `u user 1000:1000 ... $6$hash` produces UID 994 + locked password, with all the other fields ignored.
2. Salt-and-hash substitution at build time (`__CHANGEME_HASH__` sed pattern) is fragile across mkosi prepare/postinst stages.

### 8.2 Default credentials and shipped `/etc/shadow`

Both `root` and `user` are seeded with the password `changeme`, hashed in `myosi/mkosi.extra/etc/shadow`:

```
root:$6$myosirootinit$5iJ7g68...:20603:0:99999:7:::
user:$6$myosiuserinit$hny4TLIXPUZT6aYu...:20603:0:99999:7:::
```

Salts (`myosirootinit`, `myosiuserinit`) are deterministic so builds are bit-for-bit reproducible.

When the image boots:

1. `/etc` overlay (§10.5) activates with `/var/etc` on top of the verity-baked `/etc`.
2. systemd-sysusers reads `/usr/lib/sysusers.d/user.conf` and creates the `user` entry in `/etc/passwd`. It also writes a stub `/etc/shadow` entry for `user` — but only if the user does NOT already exist. Since `/etc/shadow` (lower layer) already has both `user` and `root` with the seeded hashes, sysusers preserves them.

There is no forced password change service. Default is `changeme` for both accounts; the user is expected to run `passwd` and `sudo passwd root` immediately after install. This matches the simplicity of a personal-fleet OS and avoids a service that touches the `/etc` overlay on every boot.

### 8.3 sudo

Shipped at `mkosi.extra/etc/sudoers.d/wheel`:

```
%wheel ALL=(ALL) ALL
Defaults timestamp_timeout=15
Defaults env_reset
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
```

Password required. No `NOPASSWD`. `timestamp_timeout=15` keeps sudo session for 15 minutes after a successful auth, matching common dev workflow without being too permissive.

### 8.4 SSH

Shipped at `mkosi.extra/etc/ssh/sshd_config.d/50-myosi.conf`:

```
# Hardening
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
UsePAM yes
AuthenticationMethods publickey
PubkeyAuthentication yes
PermitEmptyPasswords no

# Misc
X11Forwarding no
PrintMotd no
Subsystem sftp /usr/libexec/openssh/sftp-server

# Authorized keys come from the writable /etc overlay (or an optional confext)
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys.d/%u
```

Net: SSH always requires a pubkey, never accepts a password, never lets `root` log in.

Local console: still uses PAM password auth. The first-boot service forces a password change before any login succeeds.

### 8.5 Optional per-host password override

Default installs use the baked `/etc/shadow` plus the writable `/etc` overlay, so `passwd` updates land directly in `/var/etc`.

As an advanced option, a confext may ship `etc/shadow`. overlayfs file resolution makes the confext shadow override the image's baked shadow as the initial state of `/etc/shadow`, *until* the user changes the password (which writes to upper and shadows everything below). Way 1 from the original brainstorm; mechanism: see §7.2.

Encryption of confext shadow at rest in git: shadow files are excluded from git and the committed alternative is `age`-encrypted; the secret-handling runbook in `myosi/keys/README.md` documents both options.

---

## 9. Per-host configuration model

### 9.1 Default flow: writable `/etc` overlay + local sysext enablement

Normal hosts do not ship a host-specific confext. After install:

1. Operator runs `sudo hostnamectl hostname <name>`. The write lands in `/var/etc/hostname`.
2. Operator runs `sudo myosi extension-enable <feature>` for each desired sysext. The helper writes the matching feature drop-in under `/etc/sysupdate.extensions.d/<feature>.feature.d/enable.conf`, downloads only that feature's release asset for the running host version, and installs it in `/var/lib/extensions/`.
3. `systemd-sysext.service` merges the installed sysexts on next boot.
4. Subsequent `systemd-sysupdate --component=extensions update` invocations refresh only the enabled features.

Disabling a sysext (`sudo /usr/libexec/myosi/extension-disable <feature>`) removes both the enable drop-in and `/var/lib/extensions/<name>.raw`; a reboot guarantees the extension is fully unmerged.

### 9.2 Optional: signed confext lifecycle

Confexts remain supported for reusable signed configuration overlays (site-wide SSH keys, NetworkManager profiles, firewall zones, etc.). They are not built by default. Example sources live under `examples/confexts/`.

```
Build time (operator, locally or in CI):
  examples/confexts/<name>/ + extension-release file
    → mkosi builds <name>.confext.raw
    → signed with image.key, dm-verity hash signed
    → optionally uploaded to GitHub Releases

Install time (operator):
  sudo /usr/libexec/myosi/confext-install <name> ./<name>.confext.raw
    → install -m 0644 ./<name>.confext.raw /var/lib/confexts/<name>.raw
    → enables systemd-confext.service
    → operator reboots

Boot time (runtime):
  systemd-confext.service
    → discovers /var/lib/confexts/*.raw
    → verifies signatures
    → merges on /etc via overlayfs middle layer

Update time:
  systemd-sysupdate (if a transfer is shipped for that confext)
    → fetches new <name>.confext.raw
    → atomic swap (write-new-then-rename)
    → next confext refresh on boot (or manual systemctl reload systemd-confext)
```

### 9.3 Symlink-based sysext activation

`/etc/extensions/` is a directory of symlinks pointing into `/var/lib/extensions/*.raw`. When this directory is non-empty, systemd-sysext treats it as a whitelist: only the symlinked sysexts are merged.

Default installs do not populate `/etc/extensions/`; every `.raw` in `/var/lib/extensions/` is merged. An optional confext (or local edits in `/etc/extensions/`) can pin the activation set explicitly. Example whitelist for a Pascal-GPU desktop:

```
/etc/extensions/desktop.raw         -> /var/lib/extensions/desktop.raw
/etc/extensions/nvidia-580xx.raw    -> /var/lib/extensions/nvidia-580xx.raw
/etc/extensions/firmware.raw        -> /var/lib/extensions/firmware.raw
```

Example for a Turing+ desktop with VMs:

```
/etc/extensions/desktop.raw  -> /var/lib/extensions/desktop.raw
/etc/extensions/nvidia.raw   -> /var/lib/extensions/nvidia.raw
/etc/extensions/firmware.raw -> /var/lib/extensions/firmware.raw
/etc/extensions/virt.raw     -> /var/lib/extensions/virt.raw
```

Operators choosing the confext path should validate the activation set:

- Exactly zero or one symlink starting with `nvidia`.
- Each symlink target exists in the current sysext catalog.
- Symlink targets all live under `/var/lib/extensions/`.

### 9.4 Historical host inventory (example only)

Earlier drafts of this document treated per-host confexts as the default install path with a known fleet. The current default is local enablement (§9.1); the table below is kept as a worked example of how the same physical hosts would map to sysext sets:
| `laptop-4090` | RTX 4090 laptop | desktop + nvidia + firmware + virt |
| `desktop-3080` | RTX 3080 desktop | desktop + nvidia + firmware + virt |
| `gtx1070-host` | GTX 1070 desktop (Pascal) | desktop + nvidia-580xx + firmware |
| `(headless)` | future server host | (firmware only, or none) |

As an example: the ASUS laptop in the inventory will *not* ship asus-rog tools, openvpn, intel-microcode, or lact in v1 (those land in a future hardware-specific sysext). Until then a host that needs those bits stays on `myos`.

---

## 10. Sysext mechanics in detail

### 10.1 Build per sysext

Each sysext is a mkosi sub-image declared in `myosi/mkosi.images/<name>/mkosi.conf`. Example skeleton (`mkosi.images/desktop/mkosi.conf`):

```ini
[Distribution]
Distribution=fedora
Release=44

[Output]
Format=sysext
Output=desktop
ImageId=desktop
ImageVersion=@VERSION@

[Content]
ExtraSearchPaths=../../mkosi.extra

[Validation]
Verity=signed
VerityKey=../../keys/image.key
VerityCertificate=../../keys/image.crt
```

(CI decodes signing material from GitHub Secrets into `keys/` before building.)

### 10.2 extension-release files

Every sysext must contain `usr/lib/extension-release.d/extension-release.<name>` with:

```
ID=fedora
VERSION_ID=44
ARCHITECTURE=x86-64
SYSEXT_IMAGE_VERSION=<version>
SYSEXT_LEVEL=1
SYSEXT_SCOPE=system
```

For NVIDIA sysexts, additionally:

```
SYSEXT_KERNEL_RELEASE=<exact-kernel-version>
```

This pins activation to a specific kernel ABI. Boot-time mismatch causes systemd-sysext to refuse activation.

### 10.3 confext-release files

Confexts use the parallel mechanism. `etc/extension-release.d/extension-release.<host>`:

```
ID=fedora
VERSION_ID=44
ARCHITECTURE=x86-64
CONFEXT_IMAGE_VERSION=<version>
CONFEXT_LEVEL=1
CONFEXT_SCOPE=system
```

### 10.4 sysext / confext policy

Shipped in `/etc/systemd/sysext.conf` (verified against systemd v259 source — only `[SysExt]` section, only `Mutable=` and `ImagePolicy=` keys):

```
[SysExt]
ImagePolicy=root=signed:=absent
Mutable=no
```

`ImagePolicy=root=signed:=absent` rejects any sysext that doesn't carry a valid signature against a key in the kernel keyring. We require this even when SecureBoot is off — the signature check is kernel-side, unrelated to firmware trust. `Mutable=no` keeps `/usr` strictly read-only after sysext merge (defense in depth against unverified mutations).

Confext counterpart in `/etc/systemd/confext.conf`:

```
[ConfExt]
ImagePolicy=root=signed:=absent
Mutable=yes
```

`Mutable=yes` for confext is mandatory — without it, the merged `/etc` is read-only and breaks every late-boot service that writes config (sshd-keygen, NetworkManager state writes, etc.). With `Mutable=yes` systemd-confext keeps a writable upper layer at `/var/lib/extensions.mutable/etc/`, persistent across reboots. See §10.6 for how this interacts with the initrd-stage `/etc` overlay.

### 10.5 Key trust at boot

dm-verity signature validation runs entirely against the kernel's `.platform` keyring. No userspace cert-loading service is needed — and in fact, none can work under our hardened boot.

**How `.platform` gets populated.** The Fedora kernel ships with `CONFIG_LOAD_UEFI_KEYS=y`. At init, the kernel reads the UEFI signature db (and dbDefault on first boot) and copies every cert it finds into the in-kernel `.platform` keyring. On qemu test rigs this comes from `keys/OVMF_VARS-enrolled.fd`. On production hardware it comes from MOK certs enrolled via `mokutil --import` (shim mirrors enrolled MOK entries into UEFI db at boot, where the kernel sees them).

**How verity uses it.** The Fedora kernel also ships with `CONFIG_DM_VERITY_VERIFY_ROOTHASH_SIG_PLATFORM_KEYRING=y`. When `systemd-veritysetup` activates the root device with a signed roothash, the kernel validates the signature directly against `.platform`. systemd-sysext and systemd-confext do the same for sysext/confext `.raw` files. There is no consultation of `.machine` for verity signatures.

**Why a userspace `.machine` loader can't work and isn't needed.** Earlier iterations shipped a `myosi-load-image-cert.service` (both initrd and real-root) that ran `keyctl padd asymmetric "" %:.machine < image.crt`. Under `lockdown=integrity` (always on with SecureBoot) the kernel unconditionally blocks `add_key(2)` to `.machine` from userspace — even when the cert chains to a key in `.platform`. The service always failed `EACCES`, and was redundant in any case because `.platform` already covered every validation path. Removed.

**What must be enrolled.** Both `boot.crt` (signs sd-boot + the UKI) and `image.crt` (signs the dm-verity roothash, sysexts, and confexts) MUST be in `.platform` for the full signed chain to validate. Concretely:

- **qemu**: `keys/OVMF_VARS-enrolled.fd` contains both certs in db when generated locally. `mkosi vm` can use it via `mkosi.local.conf`. See `mkosi.local.conf.example` for the regen procedure.
- **hardware**: `mokutil --import` both certs (see §13.6).

Enrolling only `boot.crt` is a misconfiguration: the boot chain validates, but the kernel rejects the verity roothash signature with `-ENOKEY` and refuses to mount root.

**Verification on a running host.**

```bash
keyctl list %:.platform   # should list both boot.crt and image.crt
keyctl list %:.machine    # expected to be EMPTY under lockdown=integrity
dmesg | grep -iE 'verity|enokey'   # no ENOKEY messages
```

### 10.6 `/etc` overlay at boot

The verity-protected erofs root is mounted strictly read-only. Several systemd units (and tooling like sshd-keygen) write to `/etc` at runtime: `systemd-sysusers` creates the `user` entry, `systemd-machine-id-commit` finalizes the machine-id, `sshd-keygen@*` services generate host keys, `systemd-firstboot` may set locale/timezone. Without writable `/etc`, all of these fail on first boot.

myosi solves this with an overlay set up in initramfs before `switch_root`. Current shape:

```
lower (read-only) : /sysroot/usr/share/factory/etc                   (verity-baked copy of /etc)
upper (writable)  : /sysroot/var/etc                       (on btrfs /var, persistent)
work              : /sysroot/var/.etc-work                 (same fs as upper)
mount point       : /sysroot/etc                           (becomes /etc after switch_root)
```

**Why `/usr/share/factory/etc`?** It is systemd's OWN factory location — `systemd-tmpfiles` `C`/`C!` lines copy from `/usr/share/factory/` by default and the factory-reset machinery is built around it — and it matches mybox's layout (`/usr/share/factory/{etc,var}`): one factory pattern across the repo. The ostree/bootc ecosystem converges on `/usr/etc` instead; myosi deliberately prefers the systemd-native path since nothing here consumes ostree semantics. The path lives inside the verity-protected `/usr`, so the baseline is signature-protected and tamper-evident.

> **Historical note on dissect bind concern.** An earlier iteration used `/etc-factory` at the root level (outside `/usr`) on the documented assumption that `mkosi-initrd`'s `/sysroot/usr` dissect mount (`mount.usrflags=ro` → `sysusr-usr.mount` → `sysroot-usr.mount`, `MS_PRIVATE` propagation) would cause overlayfs `lowerdir=` lookup to return `-ENOENT` on paths under `/sysroot/usr/...`. Empirically tested on systemd 259.6 + mkosi v26 + kernel 7.0.11 (2026-06-11 qemu boot): the lookup resolves cleanly, the overlay assembles, `dbus-broker` + `NetworkManager` + `sshd` all start. The concern either never materialized for shallow `/usr/share/factory/etc` paths or was fixed in a kernel/systemd release between the original observation and now.

**Why bother with a separate factory copy at all?** Overlayfs requires `lowerdir != mountpoint`. An earlier iteration bind-mounted `/sysroot/etc` to `/run/myosi-etc-lower` and used the bind as lowerdir — fragile across `switch_root` because `/run` becomes a fresh tmpfs after the pivot. The factory copy gives a stable path that lives inside the verity root and stays mounted forever.

**Integration mechanism (mkosi v26):** mkosi v26 builds the initrd via its own `mkosi-initrd`, NOT dracut. Files dropped into `mkosi.extra/usr/lib/dracut/modules.d/` would be inert. The canonical way to add custom systemd content to the initrd is a separate cpio sub-image declared in `mkosi.images/` with `Format=cpio` and `Include=mkosi-initrd` (inherits the default initrd's base packages); main `mkosi.conf` references it via `Initrds=%O/initrd.cpio.zst` so the resulting cpio supersedes the default initrd.

Implementation in `mkosi.images/initrd/`:

- `mkosi.conf` — `Include=mkosi-initrd`, `Output=initrd`, `Packages=bash cryptsetup btrfs-progs util-linux`.
- `mkosi.extra/usr/libexec/myosi/sysroot-prep` — shell script: finds the boot/root disk, selects its DPS `Type=var` partition, unlocks it as `/dev/mapper/data`, unlocks present `data-N` pool members, scans btrfs, and mounts `/sysroot/var`. Uses `udevadm info` (not `blkid`) for partition metadata because `blkid` silently exits 2 on dm-verity-backed partitions.
- `mkosi.extra/usr/lib/systemd/system/sysroot-prep.service` — oneshot, `After=sysroot.mount systemd-repart.service`, `Before=sysroot-etc.mount initrd-switch-root.target`, `StandardOutput=journal+console`, `RemainAfterExit=yes`.
- `mkosi.extra/usr/lib/systemd/system/sysroot-etc.mount` — declarative `.mount`: `What=myosi-etc-overlay`, `Type=overlay`, options `index=off,metacopy=off,redirect_dir=nofollow,xino=auto`, `IgnoreOnIsolate=yes`.
- `mkosi.extra/usr/lib/systemd/system/initrd-fs.target.d/50-myosi.conf` — `Requires=sysroot-prep.service sysroot-etc.mount` (hard requirement; failure drops to emergency shell before the empty-rootfs pivot).

`mkosi.finalize` copies `/etc` to `/usr/share/factory/etc` after package install (idempotent: removes target first, then `cp -a /etc/. /usr/share/factory/etc/`) and wipes sealed-root `/etc` so the overlay owns runtime configuration.

**SELinux labeling.** `/usr/share/factory/etc` is labeled as an alias of `/etc` during `mkosi.postinst` by adding `/usr/share/factory/etc /etc` to `file_contexts.subs` before mkosi's final relabel. The initrd-created btrfs directories are relabeled by `myosi-firstboot-relabel.service`, which runs `restorecon -iRF /var /home /tmp` once on first boot for mutable state created before policy load.

**Confext interaction.** When `systemd-confext.service` activates (after `basic.target`), it mounts a SECOND overlay at `/etc`, shadowing the initrd one. The new overlay's stack:

```
lower (RO)  : confext .raw /etc content                              [signed]
lower (RO)  : the existing /etc view at activation time              [our initrd overlay collapsed into a lowerdir]
upper (RW)  : /var/lib/extensions.mutable/etc/                       [because Mutable=yes]
work        : /var/lib/extensions.mutable/.workdir.etc/
```

Result — writes split across boot phase, both persistent on the LUKS+btrfs `/var`:

| Phase | Writes go to |
|-------|--------------|
| Initrd through `basic.target` (sysusers, machine-id finalize, repart finalize) | `/var/etc` |
| After `systemd-confext.service` (sshd-keygen, NetworkManager state, post-boot edits) | `/var/lib/extensions.mutable/etc/` |

Reads at any time see the merged view: confext content > our initrd overlay > verity baseline.

**Snapshot / rollback / factory-reset story.** Both upper-layer directories (`/var/etc`, `/var/lib/extensions.mutable/etc/`) are regular paths inside the `/var` btrfs subvolume. A read-only btrfs subvolume snapshot of `/var` captures them together — `sudo btrfs subvolume snapshot -r /var /var/.snap/<name>` preserves all `/etc` mutations alongside the rest of `/var` state. Rollback is operator-driven: inspect the snapshot read-only and copy back selectively, or replace the live subvol contents at a maintenance window. To factory-reset `/etc` back to the verity-baked baseline + current confext content: boot rescue, mount `/var`, `rm -rf /var/etc/* /var/lib/extensions.mutable/etc/*`, reboot.

---

## 11. Signing model

### 11.1 Two keypairs

| Key | Algorithm | Validity | Use |
|-----|-----------|----------|-----|
| `boot.key` | RSA-4096, SHA-384 | 5 years | Signs sd-boot binary, UKIs (.efi). Enrolled as MOK on each host. |
| `image.key` | RSA-4096, SHA-384 | 5 years | Signs dm-verity root hash, sysext `.raw` verity, confext `.raw` verity. Cert loaded into kernel keyring. |

Rationale for the split:

- UEFI SecureBoot signature verification supports RSA reliably; ECDSA support varies by firmware; Ed25519 is not supported by UEFI at all.
- dm-verity root hash signatures are wrapped in **PKCS#7/CMS**, which rejects EdDSA. RSA-4096 + SHA-384 is the strongest portable PKCS#7-compatible choice for `image.key`. (Earlier drafts of this document specified Ed25519 for `image.key`; switched to RSA-4096 during build verification when CMS signing failed.)

### 11.2 Key generation

One-time, on the user's laptop, off-network:

```bash
# boot.key — RSA-4096 with code-signing EKU
openssl req -newkey rsa:4096 -keyform PEM -keyout boot.key \
  -x509 -sha384 -days 1825 -nodes \
  -subj "/CN=myosi Boot CA/O=myosi/" \
  -addext "extendedKeyUsage=1.3.6.1.5.5.7.3.3,1.3.6.1.4.1.311.10.3.6" \
  -out boot.crt

# image.key — RSA-4096 for PKCS#7/CMS compatibility
openssl req -newkey rsa:4096 -keyform PEM -keyout image.key \
  -x509 -sha384 -days 1825 -nodes \
  -subj "/CN=myosi Image CA/O=myosi/" \
  -out image.crt
```

### 11.3 Key storage

- **Private keys**: GitHub Actions Secrets (`MYOSI_BOOT_KEY`, `MYOSI_BOOT_CRT`, `MYOSI_IMAGE_KEY`, `MYOSI_IMAGE_CRT`), base64-encoded. Decrypted into `myosi/keys/` at job start, never committed.
- **Backups**: two offline copies, each encrypted with `age` and stored in two physically separate locations.
- **Local keys**: `myosi/keys/` is gitignored. `just keys-generate` creates a local keypair for local builds. CI writes release signing material to the same paths.

### 11.4 Per-host secrets

Per-host secrets (the optional confext `shadow` override) are not signing keys but follow similar rules:

- Plaintext per-host secrets live at `myosi/hosts/<host>/secrets/` and are gitignored.
- CI pulls them from per-host GH Secrets (`MYOSI_HOST_<NAME>_SHADOW`).
- The committed alternative is age-encrypted shadow with a per-host recipient.

### 11.5 Key rotation

Year 4.5 (calendar reminder):

1. Generate new keypair offline.
2. Sign latest base image and sysexts with new key during a parallel CI run.
3. Push update to one test host. Verify boot.
4. Push new public certs to repo.
5. Roll out new image-signed update to all hosts.
6. Add new MOK to each host via `mokutil --import` (boot to enroll).
7. After confirmation, retire old key from CI secrets and revoke (no CRL infra; revocation = stop signing with it).

---

## 12. Update flow (systemd-sysupdate)

### 12.1 Artifact layout in a GitHub Release

Each stable release is tagged with the bare version, `YYYY.MM.DD.NN` (e.g. `2026.05.30.02`). Prereleases append a SemVer-style suffix: `YYYY.MM.DD.NN-rc.N`, `-beta.N`, or `-alpha.N` (e.g. `2026.05.30.02-rc.1`), and are marked as prerelease on GitHub. Tags are bare (no `v` prefix) so the asset filenames and the `@v` interpolation in sysupdate transfers use the version verbatim. Sysupdate consumes only stable (non-prerelease) releases via `https://github.com/aboglioli/myosi/releases/latest/download/...`. Each release attaches:

```
myosi-<version>.raw.xz                    # full base image (root data + verity + sig, GPT-stripped)
myosi-<version>.efi                       # UKI (signed)
myosi-<version>.SHA256SUMS                # checksums
myosi-<version>.SHA256SUMS.sig            # signed by boot.key

desktop-<version>.raw                          # sysext, internally signed
desktop-<version>.SHA256

nvidia-<version>.raw
nvidia-<version>.SHA256

nvidia-580xx-<version>.raw
nvidia-580xx-<version>.SHA256

firmware-<version>.raw
firmware-<version>.SHA256

virt-<version>.raw
virt-<version>.SHA256

<name>.confext-<version>.raw                   # optional, per signed confext
<name>.confext-<version>.SHA256

sysupdate-manifest.json                        # machine-readable index for sysupdate transfers
```

### 12.2 Transfer definitions

Shipped in `/usr/lib/sysupdate.d/`:

`10-root.transfer`:

```ini
[Transfer]
ProtectVersion=%A

[Source]
Type=url-file
Path=https://github.com/aboglioli/myosi/releases/download/myosi-@v/
MatchPattern=myosi-@v.raw.xz

[Target]
Type=partition
Path=auto
MatchPattern=root-@v
MatchPartitionType=root
PartitionFlags=0
ReadOnly=1
```

`11-verity.transfer`:

```ini
[Transfer]
ProtectVersion=%A

[Source]
Type=url-file
Path=https://github.com/aboglioli/myosi/releases/download/myosi-@v/
MatchPattern=myosi-@v.verity

[Target]
Type=partition
Path=auto
MatchPattern=root-verity-@v
MatchPartitionType=root-verity
```

`12-verity-sig.transfer`:

```ini
[Transfer]
[Source]
Type=url-file
Path=https://github.com/aboglioli/myosi/releases/download/myosi-@v/
MatchPattern=myosi-@v.verity-sig

[Target]
Type=partition
Path=auto
MatchPattern=root-verity-sig-@v
MatchPartitionType=root-verity-sig
```

`20-uki.transfer`:

```ini
[Transfer]
[Source]
Type=url-file
Path=https://github.com/aboglioli/myosi/releases/download/myosi-@v/
MatchPattern=myosi-@v.efi

[Target]
Type=regular-file
Path=/efi/EFI/Linux
MatchPattern=myosi_@v.efi
TriesLeft=3
TriesDone=0
InstancesMax=2
```

`InstancesMax=2` keeps exactly two UKIs on the ESP (current + last-good).
`TriesLeft=3 TriesDone=0` enables sd-boot's boot-counting auto-rollback.

Optional sysexts are modeled as a separate `systemd-sysupdate` component named `extensions` for normal full-system updates. Transfer files live in `/usr/lib/sysupdate.extensions.d/` and are updated with the base image. Features are disabled by default. A host enables a feature by writing a local drop-in under `/etc/sysupdate.extensions.d/<feature>.feature.d/enable.conf` with `Enabled=true`. For first enablement, `myosi extension-enable` downloads only the named sysext asset for the running host version and installs it directly into `/var/lib/extensions/`; later `myosi update` refreshes all enabled sysexts together with the base.

This keeps update definitions centrally maintained while local `/etc` records only host intent. Disabling a sysext removes the local enable drop-in and the installed `/var/lib/extensions/<name>.raw`; rebooting guarantees the extension is fully unmerged.

Per-sysext transfers (one file per sysext) — example `30-desktop.transfer`:

```ini
[Transfer]
[Source]
Type=url-file
Path=https://github.com/aboglioli/myosi/releases/download/myosi-@v/
MatchPattern=desktop-@v.raw

[Target]
Type=regular-file
Path=/var/lib/extensions
MatchPattern=desktop.raw
```

Optional confext transfers are shipped *inside the confext* itself, so a host that opts into a particular confext also opts into its update channel:

`/etc/sysupdate.d/90-<name>-confext.transfer`:

```ini
[Transfer]
[Source]
Type=url-file
Path=https://github.com/aboglioli/myosi/releases/download/myosi-@v/
MatchPattern=<name>.confext-@v.raw

[Target]
Type=regular-file
Path=/var/lib/confexts
MatchPattern=<name>.confext.raw
```

### 12.3 Activation

`systemctl start systemd-sysupdate.service` (or the timer once enabled):

1. Reads all transfer definitions.
2. Queries source URL for newest matching version.
3. Downloads to inactive slot for partition targets / temp file for regular-file targets.
4. Verifies signatures (where supported by transfer type).
5. Atomic rename to live location.
6. Updates sd-boot loader entries.
7. Returns success or detailed failure.

User reboots when ready. Trigger with `sudo systemctl start systemd-sysupdate.service`.

### 12.4 Boot counter and rollback

sd-boot tracks `TriesLeft` and `TriesDone` in the UKI filename (e.g., `myosi_2026.05.30.02+3-0.efi`). On each boot attempt:

- Decrements `TriesLeft`.
- If user-space comes up and runs `bootctl set-default` or `systemd-bless-boot.service` runs successfully, the entry is "blessed" and tries-tracking stops.
- If `TriesLeft` reaches 0 without blessing, sd-boot picks the previous UKI on the next attempt.

`systemd-bless-boot.service` ships enabled. It blesses the entry only when boot fully reaches `multi-user.target`. Crash before that = no bless = decremented try count → eventual rollback.

### 12.5 Manual rollback

If the operator wants to force a previous slot even after blessing, pick the previous UKI from the sd-boot menu at the next reboot (press Space at the menu), or set the default explicitly:

```bash
sudo bootctl set-default <previous-uki-id>
sudo systemctl reboot
```

---

## 13. Install flow

### 13.1 Build the live USB image

On the user's existing workstation (running `myos` bootc):

```bash
cd ~/myenv/myosi
just build
```

This invokes `mkosi build` for the base image. Output: `myosi/build/myosi.raw` (uncompressed) + `myosi/build/myosi.raw.xz` (compressed).

Compressed image is what's flashed; mkosi can emit either.

### 13.2 Write to a block device (USB or internal disk)

A single `install.sh` script handles both flashing a boot USB and installing onto an internal disk — the destination is whichever block device you pass. The image is a full GPT disk so the operation is identical either way.

```bash
just install /dev/sdX                       # USB stick (auto-picks build/myosi_<calver>.raw)
just install /dev/nvme0n1                   # internal disk
just install /dev/nvme0n1 /dev/sdb          # clone the booted USB onto NVMe
just install /dev/sda build/myosi_VER.raw   # explicit source file
```

Checks:

- Target is a block device, not a mounted partition.
- Target is not the disk the running system was booted from (dm-verity / dm-crypt chains are resolved through `/sys/class/block/*/slaves` to reach the underlying physical disk).
- Source is at least as small as the target (only for uncompressed sources; compressed sources rely on dd to run out of space).
- User confirms with the target's serial + size displayed.

Then:

```bash
xz -dc myosi_<calver>_<arch>.raw.xz | dd of=/dev/sdX bs=4M iflag=fullblock status=progress oflag=direct conv=fsync
sync
```

### 13.3 Boot USB on target hardware

USB boots into a live myosi. Login: `user` / `changeme` (forced change). The live system is bit-for-bit the same as the installed system would be — the same image that would land on disk is running off the USB. systemd-repart sees the USB device as its target and would re-run on it; the live-USB UKI cmdline sets `systemd.firstboot=off` and `systemd.repart=no` to prevent self-modification.

### 13.4 Install to target disk

From the live USB session:

```bash
sudo just install /dev/nvme0n1
```

Recipe:

1. Confirms target disk identity (serial, size).
2. Confirms target is empty or user accepts wipe.
3. Decompresses myosi.raw and `dd`s to target.
4. Re-reads partition table.
5. Reboots into the installed system. LUKS passphrase is prompted at first boot by systemd-repart (see §13.5), not at install time.

### 13.5 First boot on installed system

1. Firmware loads shim → sd-boot → UKI from new disk's ESP.
2. systemd-repart runs:
   - Detects ESP, root-a, root-a-verity, root-a-verity-sig exist.
   - Detects data-luks partition exists but is "factory reset" marked.
   - Prompts user via `systemd-ask-password`: "Enter passphrase for /var:"
   - Formats LUKS, creates btrfs, creates subvols.
3. systemd-cryptsetup unlocks (using just-set passphrase).
4. btrfs mounts complete.
5. systemd-sysusers reads `/usr/lib/sysusers.d/user.conf` and creates `user` (UID 1000, fish shell, group memberships) in the `/etc` overlay. The shipped `/etc/shadow` hashes are preserved.
6. User logs in on console with `user` / `changeme`. Runs `passwd` and `sudo passwd root` to replace the seed passwords.
7. User sets the local hostname and enables the desired sysexts:

   ```bash
   sudo hostnamectl hostname <name>
   sudo /usr/libexec/myosi/extension-enable containers
   # add desktop / virt / nvidia* / nvidia-580xx as the host needs
   ```

   `extension-enable` writes the feature drop-in under `/etc/sysupdate.extensions.d/`, downloads only the named release asset for the running host version, installs it in `/var/lib/extensions/`, and refreshes the sysext overlay.

8. Reboot. sysexts merge. Host now runs with the enabled feature set.
9. Optional: `sudo /usr/libexec/myosi/enroll-tpm` adds TPM2 unlock for future reboots.
10. Optional: install a reusable signed confext with `sudo /usr/libexec/myosi/confext-install NAME ./NAME.confext.raw`.

### 13.6 SecureBoot enrollment

After successful first boot, if SecureBoot is desired, enroll **both** myosi keys:

```bash
sudo mokutil --import /usr/share/myosi/keys/boot.crt
sudo mokutil --import /usr/share/myosi/keys/image.crt
```

Prompts for an enroll-time password each time. Reboot. MOK Manager appears, user navigates to "Enroll MOK," enters the password, confirms — once per cert. Reboot. Subsequent boots validate the full chain.

`boot.crt` is required to chain-load sd-boot and the UKI through shim. `image.crt` is required because the kernel validates the dm-verity roothash signature (and sysext/confext signatures) against the `.platform` keyring, which is populated from UEFI db / MOK at init via `CONFIG_LOAD_UEFI_KEYS`. Enrolling only `boot.crt` leaves `image.crt` out of `.platform`, the kernel rejects the verity signature with `-ENOKEY`, and root fails to mount. See §10.5.

If SecureBoot is disabled, MOK enrollment is skipped. The image still boots and works correctly — `.platform` is empty but verity falls back to unsigned validation when no signature is required.

---

## 14. Operations runbooks

### 14.1 Day-2 update

```bash
sudo systemctl start systemd-sysupdate.service
sudo journalctl -u systemd-sysupdate.service -n 50
```

Triggers sysupdate. Operator reviews output, reboots when ready.

### 14.2 Take a manual snapshot

```bash
sudo btrfs subvolume snapshot -r /var  /var/.snap/before-podman-pull
sudo btrfs subvolume snapshot -r /home /home/.snap/before-nvim-plugins
```

List with:

```bash
sudo btrfs subvolume list /var  | grep .snap/
sudo btrfs subvolume list /home | grep .snap/
```

Delete with:

```bash
sudo btrfs subvolume delete /var/.snap/before-podman-pull
```

### 14.3 Rollback a state snapshot

Read-only snapshots aren't auto-applied. Two operator paths:

```bash
# Inspect snapshot read-only and copy back selectively
sudo mkdir /mnt/snap-recovery
sudo mount -o subvol=var/.snap/before-podman-pull /dev/mapper/data /mnt/snap-recovery
sudo cp -a /mnt/snap-recovery/<paths-you-want> /var/<dest>/
sudo umount /mnt/snap-recovery
```

```bash
# Full swap at maintenance window (reboot recommended for /var)
sudo btrfs subvolume snapshot /var/.snap/before-podman-pull /var.new
# stop services touching /var, swap mount, reboot
```

### 14.4 Force root rollback

Pick the previous UKI from the sd-boot menu at boot (press Space), or set the default and reboot:

```bash
sudo bootctl set-default <previous-uki-id>
sudo systemctl reboot
```

### 14.5 Enroll TPM2

```bash
sudo /usr/libexec/myosi/enroll-tpm
```

Wraps `systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 /dev/<luks-partition>`. Prints recovery passphrase reminder.

### 14.6 Remove TPM2 enrollment

```bash
sudo /usr/libexec/myosi/remove-tpm
```

Wraps `systemd-cryptenroll --wipe-slot=tpm2`.

### 14.7 Factory-reset /etc

When `/var/etc` has drifted enough to cause confusion:

1. Reboot to a recovery shell (sd-boot extra entry or USB).
2. Unlock LUKS, mount `/var` subvol.
3. `rm -rf /var/etc/* /var/lib/extensions.mutable/etc/*`.
4. Reboot. Image defaults + confext apply fresh.

### 14.8 Disaster recovery: lost passphrase, no TPM

Two cases:

- **TPM enrolled**: boot proceeds, TPM unlocks. Set new passphrase via `systemd-cryptenroll --password /dev/<luks>`.
- **No TPM**: data is lost. /var and /home unrecoverable. Reinstall (USB → `just install`). /home backup procedure is the operator's separate responsibility.

A printed recovery passphrase, stored in a safe, is the cheap mitigation. Document this in the install runbook.

### 14.9 SecureBoot toggle survives the TPM enrollment

If the operator toggles SB on/off after TPM enrollment, PCR 7 changes and TPM unlock fails. Boot falls back to passphrase. Operator can re-enroll TPM2 after the toggle stabilizes:

```bash
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/<luks>
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 /dev/<luks>
```

---

## 15. Repo layout

```
myenv/myosi/
├── README.md                                       # user-facing quickstart
├── docs/
│   └── design.md                                   # this document
├── justfile                                        # all operator recipes
├── .gitignore                                      # keys/, build/, hosts/*/secrets/, *.raw
│
├── mkosi.conf                                      # base image definition
├── mkosi.local.conf.example                        # per-dev override template (gitignored when copied)
│
├── mkosi.repart/                                           # build-time GPT partition definitions
│   ├── 00-esp.conf
│   ├── 10-root-a-verity-sig.conf
│   ├── 11-root-a-verity.conf
│   └── 12-root-a.conf
│
├── mkosi.extra/                                    # files copied into base /
│   ├── etc/
│   │   ├── hostname
│   │   ├── locale.conf
│   │   ├── vconsole.conf
│   │   ├── os-release
│   │   ├── ssh/sshd_config.d/50-myosi.conf
│   │   ├── sudoers.d/wheel
│   │   ├── systemd/sysext.conf
│   │   ├── systemd/confext.conf
│   │   ├── dnf/dnf5.conf
│   │   └── NetworkManager/conf.d/00-myosi.conf
│   └── usr/
│       ├── lib/
│       │   ├── repart.d/                                  # runtime/initrd repart layout
│       │   ├── sysusers.d/user.conf
│       │   ├── tmpfiles.d/
│       │   │   ├── myosi.conf
│       │   │   ├── home.conf
│       │   │   └── libvirt.conf
│       │   ├── systemd/system/
│       │   │   ├── myosi-firstboot-relabel.service
│       │   │   └── sshd-vsock@.service.d/10-mkosi-cred.conf
│       │   ├── systemd/system-preset/50-myosi.preset
│       │   ├── sysupdate.d/
│       │   │   ├── 10-root.transfer
│       │   │   ├── 11-verity.transfer
│       │   │   ├── 12-verity-sig.transfer
│       │   │   └── 20-uki.transfer
│       │   ├── sysupdate.extensions.d/
│       │   │   ├── 30-desktop.transfer
│       │   │   ├── 31-nvidia.transfer
│       │   │   ├── 32-nvidia-580xx.transfer
│       │   │   ├── 33-firmware.transfer
│       │   │   ├── 34-virt.transfer
│       │   │   ├── 35-containers.transfer
│       │   │   └── *.feature
│       ├── libexec/myosi/
│       │   ├── add-data-disk
│       │   ├── convert-pool
│       │   ├── create-data-pool
│       │   └── enroll-host
│       └── share/
│           └── myosi/
│               └── version
│
└── mkosi.images/initrd/                # cpio sub-image — see §10.6
    ├── mkosi.conf                                   # Include=mkosi-initrd, Packages=bash cryptsetup btrfs-progs util-linux
    └── mkosi.extra/
        ├── usr/libexec/myosi/
        │   └── sysroot-prep                         # find root disk, unlock Type=var, unlock data-N pool, mount /sysroot/var
        └── usr/lib/systemd/system/
            ├── sysroot-prep.service                 # oneshot, After=sysroot.mount systemd-repart.service
            ├── sysroot-etc.mount                    # overlay mount (declarative)
            └── initrd-fs.target.d/50-myosi.conf    # Requires= both units
│
├── mkosi.prepare                                   # build-time prep script
├── mkosi.postinst                                  # build-time post-install fixups
│
├── packages/                                       # reusable package lists
│   ├── base.list
│   ├── desktop.list
│   ├── nvidia.list
│   ├── nvidia-580xx.list
│   ├── firmware.list
│   └── virt.list
│
├── mkosi.images/                                   # sysext sub-images
│   ├── desktop/
│   │   ├── mkosi.conf
│   │   ├── mkosi.prepare
│   │   ├── mkosi.postinst
│   │   └── mkosi.extra/
│   │       └── usr/
│   │           ├── lib/
│   │           │   ├── extension-release.d/extension-release.desktop
│   │           │   └── systemd/system/flatpak-setup-flathub.service
│   │           └── ...
│   ├── nvidia/
│   │   ├── mkosi.conf
│   │   ├── mkosi.prepare                           # pins kernel version
│   │   ├── mkosi.postinst                          # builds akmod
│   │   └── mkosi.extra/usr/lib/extension-release.d/extension-release.nvidia
│   ├── nvidia-580xx/
│   │   ├── mkosi.conf
│   │   ├── mkosi.prepare                           # _without_kmod_nvidia_detect=1
│   │   ├── mkosi.postinst
│   │   └── mkosi.extra/usr/lib/extension-release.d/extension-release.nvidia-580xx
│   ├── firmware/
│   │   ├── mkosi.conf
│   │   └── mkosi.extra/usr/lib/extension-release.d/extension-release.firmware
│   └── virt/
│       ├── mkosi.conf
│       ├── mkosi.postinst
│       └── mkosi.extra/usr/lib/extension-release.d/extension-release.virt
│
├── examples/
│   └── confexts/                                   # reusable confext templates (not built by default)
│       └── site/
│           ├── confext.conf
│           ├── extra/
│           │   └── etc/
│           │       ├── extensions/                 # optional explicit activation set
│           │       │   ├── desktop.raw -> /var/lib/extensions/desktop.raw
│           │       │   ├── nvidia.raw -> /var/lib/extensions/nvidia.raw
│           │       │   └── firmware.raw -> /var/lib/extensions/firmware.raw
│           │       ├── ssh/authorized_keys.d/user
│           │       ├── NetworkManager/system-connections/
│           │       ├── extension-release.d/extension-release.site
│           │       └── sysupdate.d/90-site-confext.transfer
│           ├── secrets/                            # gitignored
│           │   └── shadow.age                      # age-encrypted, optional
│           └── README.md                           # template notes
│
├── keys/
│   ├── README.md                                   # generation + rotation runbook
│   ├── .gitignore                                  # ignore key material and OVMF varstore
│   ├── generate-keys.sh
│   ├── boot.key                                    # gitignored
│   ├── boot.crt                                    # gitignored, shipped in image when present
│   ├── image.key                                   # gitignored
│   ├── image.crt                                   # gitignored, shipped in image when present
│   └── OVMF_VARS-enrolled.fd                       # gitignored, generated locally for qemu SB
│
├── ci/                                             # GitHub Actions
│   ├── build.yml                                   # reusable workflow
│   └── lib/
│       ├── sysupdate-manifest.sh
│       ├── lint-confext.sh
│       └── decode-keys.sh
│
└── install/
    ├── install.sh                                  # callable by `just install` — writes the image to a USB or an internal disk
    ├── partition-target.md                         # manual install runbook
    └── post-install-checklist.md
```

Top-level `.github/workflows/myosi.yml` is a thin wrapper:

```yaml
name: myosi
on:
  push:
    branches: [main]
    paths: ['myosi/**', '.github/workflows/myosi.yml']
  workflow_dispatch:
jobs:
  build:
    uses: ./.github/workflows/myosi-build.yml
```

with `.github/workflows/myosi-build.yml` invoking the work defined in `myosi/ci/build.yml` for actual logic (kept under `myosi/` for self-containment per Q1; the file in `.github/workflows/` is the minimum the platform requires at that path).

---

## 16. Justfile recipes

`myenv/myosi/justfile`:

```just
# Show available recipes
default:
    @just --list

# Generate local dev signing keys
keys-generate:
    ./scripts/generate-keys.sh

# Build a single image or all images
build target="all":
    mkosi --image={{target}} build

# Boot base image in qemu with OVMF
qemu image="myosi":
    mkosi --image={{image}} qemu

# Boot base image in systemd-nspawn for quick iteration
nspawn image="myosi":
    mkosi --image={{image}} boot

# Safety-checked flash to USB
install device source="":
    sudo ./install/install.sh {{device}} {{source}}

# Enable an optional sysext feature (downloads one release asset, installs, registers feature)
extension-enable name version="":
    # Implemented inline in justfile: downloads the named sysext asset,
    # writes the feature drop-in, then refreshes systemd-sysext.

# Disable an optional sysext feature (removes /var/lib/extensions/<name>.raw + drop-in)
extension-disable name:
    # Implemented inline in justfile: removes the feature drop-in and installed image,
    # then vacuums the extensions component.

# Install a local confext .raw
confext-install name path:
    sudo install -m 0644 {{path}} /var/lib/confexts/{{name}}.raw
    sudo systemctl enable systemd-confext.service
    sudo systemd-confext refresh || sudo systemctl reboot

# Remove a confext
confext-remove name:
    sudo rm -f /var/lib/confexts/{{name}}.raw

# Enroll TPM2 keyslot for LUKS auto-unlock
enroll-tpm:
    sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 $(findmnt -no SOURCE /var | sed 's|/dev/mapper/||;s|^|/dev/disk/by-partlabel/|')

# Remove TPM2 keyslot
remove-tpm:
    sudo systemd-cryptenroll --wipe-slot=tpm2 $(findmnt -no SOURCE /var | sed 's|/dev/mapper/||;s|^|/dev/disk/by-partlabel/|')

# Run sysupdate now
update:
    sudo systemctl start systemd-sysupdate.service
    sudo journalctl -u systemd-sysupdate.service -n 50 --no-pager

# Snapshots: use raw `btrfs subvolume` directly — no snapper recipes
#   sudo btrfs subvolume snapshot -r /home /home/.snap/<name>
#   sudo btrfs subvolume list /home | grep .snap/
#   sudo btrfs subvolume delete /home/.snap/<name>

# Show active sysexts
sysext-list:
    sudo systemd-sysext list

# Show active confexts
confext-list:
    sudo systemd-confext list

# Validate a confext build without producing the image
lint-confext host:
    ./scripts/lint-confext.sh hosts/{{host}}
```

---

## 17. CI workflow shape

`myosi/ci/build.yml` (logical content; the file at `.github/workflows/myosi-build.yml` calls into this):

```yaml
name: myosi-build
on:
  workflow_call:

env:
  MYOSI_VERSION: ${{ github.event.repository.updated_at }}-${{ github.sha }}

jobs:
  base:
    runs-on: ubuntu-24.04
    outputs:
      kernel: ${{ steps.kernel.outputs.version }}
    steps:
      - uses: actions/checkout@v4
      - name: Install mkosi + deps
        run: |
          sudo apt-get update
          sudo apt-get install -y mkosi systemd-container squashfs-tools erofs-utils \
                                   sbsigntool pesign openssl xz-utils
      - name: Decode keys
        run: ./myosi/scripts/decode-keys.sh
        env:
          MYOSI_BOOT_KEY: ${{ secrets.MYOSI_BOOT_KEY }}
          MYOSI_BOOT_CRT: ${{ secrets.MYOSI_BOOT_CRT }}
          MYOSI_IMAGE_KEY: ${{ secrets.MYOSI_IMAGE_KEY }}
          MYOSI_IMAGE_CRT: ${{ secrets.MYOSI_IMAGE_CRT }}
      - name: Build base
        run: cd myosi && mkosi --image=myosi build
      - name: Extract kernel version
        id: kernel
        run: |
          KVER=$(strings myosi/build/myosi.raw | grep -oP 'kernel-\K[\d.+\-fc\d]+' | head -1)
          echo "version=$KVER" >> $GITHUB_OUTPUT
      - uses: actions/upload-artifact@v4
        with:
          name: base
          path: myosi/build/myosi*

  sysext:
    needs: base
    runs-on: ubuntu-24.04
    strategy:
      matrix:
        image: [desktop, nvidia, nvidia-580xx, firmware, virt]
    steps:
      - uses: actions/checkout@v4
      - name: Install mkosi + deps
        run: |
          sudo apt-get update
          sudo apt-get install -y mkosi erofs-utils openssl xz-utils
      - name: Decode keys
        run: ./myosi/scripts/decode-keys.sh
        env:
          MYOSI_IMAGE_KEY: ${{ secrets.MYOSI_IMAGE_KEY }}
          MYOSI_IMAGE_CRT: ${{ secrets.MYOSI_IMAGE_CRT }}
      - name: Build sysext
        env:
          PINNED_KERNEL: ${{ needs.base.outputs.kernel }}
        run: cd myosi && mkosi --image=${{ matrix.image }} build
      - uses: actions/upload-artifact@v4
        with:
          name: sysext-${{ matrix.image }}
          path: myosi/build/${{ matrix.image }}*.raw

  # Confexts are optional, not built by default. When a confext template under
  # examples/confexts/<name> is promoted to a release artifact, add a job mirroring
  # the sysext job above (lint, decode keys + optional secret, mkosi build, upload).

  release:
    needs: [base, sysext]
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          path: artifacts
      - name: Generate sysupdate manifest
        run: ./myosi/scripts/sysupdate-manifest.sh artifacts > artifacts/sysupdate-manifest.json
      - name: Sign SHA256SUMS
        run: |
          ./myosi/scripts/decode-keys.sh
          cd artifacts
          find . -name '*.raw' -o -name '*.efi' -o -name '*.xz' | sort | xargs sha256sum > SHA256SUMS
          openssl dgst -sha384 -sign /tmp/myosi-keys/boot.key -out SHA256SUMS.sig SHA256SUMS
        env:
          MYOSI_BOOT_KEY: ${{ secrets.MYOSI_BOOT_KEY }}
      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: myosi-${{ env.MYOSI_VERSION }}
          files: |
            artifacts/**
          prerelease: true
          generate_release_notes: false
```

Notes:

- CI uses Ubuntu runners with mkosi from apt. Building Fedora 44 images from Ubuntu is fully supported by mkosi.
- Keys are decoded into `/tmp/myosi-keys/` (a tmpfs on the runner) and never written to persistent disk.
- The base job emits `kernel` as an output so sysext jobs pin to the same kernel version.

---

## 18. Milestone plan

All five sysexts and full stack scaffolded from v1. Milestones are about proving each layer end-to-end.

| Milestone | Scope | Exit criteria |
|-----------|-------|---------------|
| **v1** | Full scaffold buildable. `just qemu` boots base image in qemu OVMF with locally generated SecureBoot keys. dm-verity validates. /var formats on first boot, prompts passphrase. `just install /dev/sdX` works on a sacrificial USB. | Local build green; qemu boot reaches login prompt; sysexts merge in qemu; no smoke-test regressions. |
| **v2** | First real-hardware install on the user's least-critical host (e.g., a spare desktop). MOK enrollment validated. Snapshot/rollback verified manually on that host. | One host on myosi for at least a week without escalation. |
| **v3** | systemd-sysupdate end-to-end from GitHub Releases on the v2 host. A/B slot swap verified. Boot-counter rollback verified by intentionally breaking a UKI. | One successful update + one forced rollback both succeed end-to-end. |
| **v4** | TPM2 enrollment on the v2 host. SB on/off dual-mode validated. confext refresh verified. | Both modes boot successfully; TPM unlock works in SB-on mode; passphrase fallback works in SB-off mode. |
| **v5** | Roll out to all five known hosts. Decide whether `myos` bootc is retired or kept as per-host fallback. | All hosts running myosi for two consecutive weeks. |

---

## 18a. Deliberate divergences from myos

Cataloging where myosi consciously departs from the sibling project. Each is a decision, not an oversight.

| Area | myos | myosi | Reason |
|------|------|-------|--------|
| Rootless container networking | slirp4netns | **pasta** (`/etc/containers/containers.conf default_rootless_network_cmd = "pasta"`) | pasta is faster (kernel-based packet shuttling), has full IPv6, and is podman 5.x+ default. slirp4netns is the legacy fallback. |
| Nix preinstall | yes (`/nix` symlink at build time) | **no** | Atomic signed OS; arbitrary user-space package managers in the verity-protected root undermine that. Nix lives in the distrobox dev container (`myenv/Containerfile.dev`). |
| Homebrew preinstall | yes (`/home/linuxbrew`) | **no** | Same reason as Nix. brew lives in distrobox. |
| `/etc` model | layered via ostree 3-way merge | overlay (lower=verity-baked, upper=`/var/etc`, plus confext) — see §10.6 | mkosi has no ostree; manual overlay matches the immutable-OS philosophy and is fully systemd-native. |
| Host config | host-specific OCI image variant | signed confext (~1 MB) | One signed base image for all hosts; confext version-pins identity separately. Tiny update surface per host. |
| `/etc` shipping path | bootc 3-way merge handles `/usr/etc` → `/etc` at install time | repo files ship to `/etc` directly via `mkosi.extra/etc/`; mkosi.postinst snapshots `/etc` → `/usr/share/factory/etc` as the overlay lowerdir | bootc's install-time copy is absent in sysupdate. Shipping at `mkosi.extra/usr/share/factory/etc/` would leave files inert. Consolidating source paths at `/etc` and snapshotting build-side keeps source = runtime layout. |
| Forced first-boot password change | `chage -d 0` via systemd service | **no service** — user runs `passwd` after install | Personal-fleet OS, not a multi-tenant system. One less service touching the `/etc` overlay on boot. |
| Distribution | GHCR registry | GitHub Releases (signed `.raw` files) | sysupdate consumes signed assets directly; no container-registry middleware. |
| Kernel arguments | bootc `kargs.d/*.toml` | baked into signed UKI cmdline (`mkosi.conf KernelCommandLine=`) | UKI is the unit of integrity; cmdline drift between bootloader and kernel is impossible. |
| zram | optional, configured per-profile | **always on** via shipped `/etc/systemd/zram-generator.conf` | Memory compression is unambiguously useful for all 4 hosts. No reason to make it optional. |

---

## 19. Out of scope (deferred to post-v1)

| Item | Reason |
|------|--------|
| `dev.raw` sysext | Core CLI is in base; richer dev tooling (extra COPRs, language toolchains beyond mise) defers. |
| `gaming.raw` sysext (Steam, gamescope, lutris) | Significant package set; needs separate test on real GPU hardware. |
| `moby.raw` sysext (asus-rog, openvpn, lact, intel-microcode) | ASUS-specific bits. |
| `tailscale.raw` sysext | One package, deferred for simplicity in v1. |
| Headless Wayland + Sunshine container | Separate architectural question (Incus profile). |
| Public update channel | Stay private until stable. |
| Automatic sysupdate timer enabled by default | Operator opts in. |
| ISO installer | Raw USB suffices. |
| Multi-distro support | Fedora 44 only. |
| Automatic snapshot hooks on sysupdate | Operator-triggered only per Q14. |
| `composefs` migration | We chose dm-verity for v1; composefs revisit if delta updates become critical. |
| `systemd-pcrlock` automatic re-enrollment across UKI updates | Manual re-enrollment after big SB changes for now. |
| Backup / off-site replication for `/home` | Separate concern. |

---

## 20. Open questions and risks

### 20.1 Open questions

- **mkosi version on Fedora 44 runners.** Ubuntu 24.04 apt mkosi is currently behind upstream; we may need to install mkosi from pip or build from source to get `mkosi.images/` and recent verity signing features. To be validated during v1.
- **incus packaging on F44.** COPR `ganto/lxc4` is the candidate. If unavailable or stale at build time, fallback is upstream tarball install in mkosi.postinst. To be validated.
- **akmod build inside mkosi sysext build.** mkosi sub-image build runs in a containerized environment; building kernel modules requires the kernel-devel package matching the base image's kernel. The base job's `kernel` output is the version coordinate; sysext jobs install matching `kernel-devel`. Validation needed.
- **systemd-sysupdate URL transfer support for GitHub Releases.** sysupdate's `url-file` transfer expects a directory-listing-style index. GitHub Releases serves direct asset URLs but no parent directory listing. We may need to use a manifest file (sysupdate's `MatchPattern` with the manifest source) or generate a per-release HTML index. To be validated during v3.
- **Image cert load + `/etc` overlay in initrd.** Resolved: `/etc` overlay implemented via cpio sub-image `mkosi.images/initrd/` (Include=mkosi-initrd, declarative `sysroot-prep.service` + `sysroot-etc.mount`). See §10.6. Original dracut-module approach was inert because mkosi v26 builds the initrd itself, not via dracut. The companion image-cert load service was found redundant — dm-verity validates against `.platform` (populated from UEFI db / MOK) directly, and `lockdown=integrity` blocks userspace writes to `.machine` anyway. See §10.5.

### 20.2 Risks

- **First-boot repart prompting for passphrase.** Some hardware does not initialize a console early enough for `systemd-ask-password` to render correctly. Mitigation: ship a fallback emergency shell that lets the user run repart manually.
- **MOK enrollment friction.** Each new host needs `mokutil --import` + reboot + interactive MOK Manager. There is no way around the interactive step (intentional by shim). Operator must be physically present or have IPMI / remote console.
- **NVIDIA kmod ABI drift.** A base kernel bump forces NVIDIA sysext rebuild. CI must atomically publish both or the host gets a half-broken activation. Mitigation: CI release job only publishes when *all* matrix builds succeed.
- **Confext shipping `etc/shadow` overrides** is off-label (per Q9 discussion). Risk: future systemd versions may enforce stricter confext content policies. Mitigation: monitor systemd release notes; have a fallback plan to switch to Way 2 (oneshot applies hashes to upper layer) if the off-label use is ever blocked.
- **No automatic rollback on user-space failure.** If a sysext breaks user-space but kernel boots fine, sd-boot will bless the entry. Recovery requires operator action (`bootctl set-default <previous-uki>` then reboot, or pick the previous slot at the sd-boot menu). Mitigation: this is the accepted design per Q14; document clearly.
- **GitHub Releases 2 GiB cap on per-file assets.** Base image grows over time. Sysext catalog growth is bounded but the base image is the constraint. Mitigation: aggressive base minimization, fallback plan to migrate to Cloudflare R2.

---

## 21. References

- mkosi documentation: `man mkosi`, `man mkosi.conf`, `man mkosi.preset` (upstream).
- systemd documentation: `systemd-sysext(8)`, `systemd-confext(8)`, `systemd-sysupdate(8)`, `systemd-repart(8)`, `systemd-cryptenroll(8)`, `systemd-boot(7)`, `systemd-bless-boot.service(8)`.
- dm-verity: `Documentation/admin-guide/device-mapper/verity.rst` in the kernel tree.
- erofs: `Documentation/filesystems/erofs.rst`.
- shim + MOK: https://github.com/rhboot/shim
- sd-boot Boot Loader Specification: https://uapi-group.org/specifications/specs/boot_loader_specification/
- UEFI SecureBoot: UEFI Specification ≥ 2.6, Chapter 32.
- bootc (for comparison): https://containers.github.io/bootc/
- Existing reference implementations of similar stacks: Azure Linux, ChromeOS, GNOME OS Nightly, BlueBuild "Image Definition" docs.

---

## Changelog

- 2026-05-30 — initial draft v0.1 (Q1–Q15 + virt sysext additions).

- 2026-06-08 — externy stabilization wave (boot ordering, sysext writability, operator surfaces).

  Boot-time service hygiene:
  - `myosi-firmware-reprobe.service`: cycle drivers post-pivot since `mkosi-initrd` ignores `rd.driver.blacklist=` (dracut-only). Does `modprobe -r iwlmvm; modprobe -r iwlwifi; modprobe iwlwifi` + same for `btusb` to recover from initrd firmware -ENOENT. Slot `DefaultDependencies=no` + `After=systemd-sysext.service` + `Before=sysinit.target` + `WantedBy=sysinit.target`. cs35l41 / snd_sof variants dropped after empirical survey showed they don't bind on stock hardware.
  - `myosi-glib-schemas-compile.service`: compile the **union** of every merged sysext's `*.gschema.xml` to `/run/myosi/glib-schemas/glib-2.0/schemas/gschemas.compiled` at boot, then expose via `GSETTINGS_SCHEMA_DIR` env.d. `strip_to_sysext_layout` now removes per-sysext `gschemas.compiled` unconditionally — generic to any future sysext. Slot at `multi-user.target` after a `Before=basic.target + RequiresMountsFor=/usr/share/glib-2.0/schemas` attempt closed an ordering cycle via mount dependencies. Replaces the earlier "only desktop sysext keeps its compiled cache" half-fix.
  - `myosi-sysusers-after-sysext.service`: re-run `systemd-sysusers` after sysext merge so sysext-shipped `sysusers.d/` (virt's `qemu`, `pcscd`, …) actually creates users. Upstream `systemd-sysusers.service` races with `systemd-sysext.service` in sysinit. Without this, virt's `qemu` user is missing → virtqemud aborts → `sudo virsh list` returns `Connection reset by peer`. Slot identical to `myosi-firmware-reprobe.service`.

  Sysext compositing fixes (recurring `strverscmp` gotcha):
  - `2026.06.08.07-rc.2 > 2026.06.08.07` in `strverscmp()` (longer string with `-rc.N` suffix wins). Bites BOTH `systemd-sysupdate` (release picker) AND `systemd-sysext` (overlay layer order). On any host that has both versions staged, rc.2 shadows the final release everywhere. Cleanup: `sudo rm /var/lib/extensions/*_<VER>-rc.*.raw; sudo systemd-sysext refresh`. Forward fix: drop `-rc.N` tagging or switch to Debian-tilde convention (`2026.06.08.07~rc.2 < 2026.06.08.07`).
  - `strip_to_sysext_layout` strips `gschemas.compiled` from every sysext unconditionally. Replaces the doomed "desktop keeps the cache" policy (nvidia / virt sysexts that pulled libvirt or polkit-gnome shipped 48 KB caches that won the overlay race).

  Marker normalization:
  - All "run-once" oneshot completion markers consolidated under `/var/lib/myosi/.marks/<task>.done`:
    - `/var/lib/myosi/.relabeled` → `.marks/firstboot-relabel.done`
    - `/var/lib/myosi/flathub-setup.done` → `.marks/flathub-setup.done`
  - `tmpfiles.d/myosi.conf` declares `d /var/lib/myosi/.marks` so the dir exists before any oneshot touches into it.
  - CI guard rejects any `ConditionPathExists=!?/var/lib/myosi/...` that doesn't match `/var/lib/myosi/.marks/*.done` — convention-violation detection at PR time.

  Sealed-root symlink expansions (`/<dir>` → `var/<dir>` postinst pattern):
  - `/mnt → var/mnt` (postinst step 9b) for operator-mounted block devices (USB drives, foreign rootfs during migration, NFS shares). Paired with `d /var/mnt 0755 root root -` in `tmpfiles.d`. Matches Silverblue / bootc / image-mode RHEL canon. Without this, `sudo mkdir /mnt/foo` fails with EROFS on the sealed erofs root.
  - Existing `/root → var/roothome` (step 9) remains the precedent.

  NFS client support:
  - `nfs-utils` added to base packages. Kernel modules (`nfs / nfsv3 / nfsv4 / sunrpc / lockd`) already shipped via `kernel-modules-extra`; the userspace `mount.nfs` helper was missing, so `mount -t nfs` failed with the generic "you might need /sbin/mount.<type> helper" error. Now operator can `sudo mount -t nfs -o vers=4 host:/path /mnt/share` directly. Server-side units (`nfs-server.service`, `rpcbind.service`) ship masked — opt-in for export hosts.

  Operator CLI consolidation:
  - `myenv` converted from a fish function to a portable bash script at `~/myenv/bin/myenv` (Linux + macOS, bash 3.2+ — no GNU-specific tools, no `readarray`). Symlinked into `~/.local/bin/myenv` by `myenv setup-config`. Fish wrapper dropped; `cd $MYENV` used directly for repo navigation.
  - `myosi`'s sysupdate backend stays on the raw `/usr/lib/systemd/systemd-sysupdate` binary, surfaced as a short `sysupdate` command via `/usr/local/bin/sysupdate → /usr/lib/systemd/systemd-sysupdate` symlink. `lib.sh::sysupdate_env` defaults to `MYOSI_SYSUPDATE_BIN=sysupdate` with documented one-env-var flip to `updatectl` when Fedora's `selinux-policy` ships `systemd_sysupdate_t` rules (currently absent on F44; experimented with a CIL module + drop-in, reverted as the binary-direct path works under operator `unconfined_t` without policy work).
  - `tmpfiles.d`: `Z /var/lib/sysupdate - root root - -` and same for `/var/lib/extensions` enforce root-ownership of staged artifacts. Rootless container builds drop release files with uid 100000 (host userns remap); `systemd-sysupdate` silently ignores non-root sources and reports the new release as "missing." Z entries normalize ownership on every boot.

  Desktop session improvements:
  - `fontconfig` moved from desktop sysext to base. The Fedora RPM ships `/etc/fonts/fonts.conf` + symlinks alongside `/usr/share/fontconfig/conf.avail/`. Sysext finalize stripped `/etc`, so the master config went missing and every GUI app warned `Fontconfig error: Cannot load default config file` on launch. Base ships it via the `/usr/share/factory/etc` snapshot mechanism.
  - Niri config (`config/niri/config.kdl`): `prefer-no-csd` enabled (kills client title bars in GTK / Qt / Electron); `spawn-at-startup "nm-applet" "--indicator"` and `spawn-at-startup "blueman-applet"` autostart the tray applets (replaces the missing `/etc/xdg/autostart/*.desktop` files that the desktop sysext can't ship); `spawn-sh-at-startup "dbus-update-activation-environment --systemd DISPLAY XAUTHORITY WAYLAND_DISPLAY XDG_SESSION_TYPE XDG_CURRENT_DESKTOP"` syncs the late-arriving wayland env into the dbus activation env so Steam Flatpak and other xdg-portal-activated apps see `DISPLAY` (niri-session's own `dbus-update-activation-environment --all` call runs **before** xwayland-satellite sets `DISPLAY=:0`, so the upstream wrapper alone isn't enough).
  - Waybar config (`config/waybar/`): renamed `config.json` → `config.jsonc` (waybar v0.15.0 only searches `config.jsonc` and `config`, dropped `.json`); layout simplified to a right-aligned bar with `pulseaudio`, `pulseaudio#source`, `tray`, `clock`. Drops CPU / memory / network / battery clutter.

  environment.d safety:
  - All `/usr/lib/environment.d/*.conf` files now hard-code XDG/path spec defaults inline instead of relying on `${VAR:-default}` (unsupported by `systemd-environment-d-generator` — same gap that bit GSettings env.d earlier). Concrete impact: `45-myosi-local-bin.conf` writes `PATH=${HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:${PATH}` rather than `PATH=${HOME}/.local/bin:${PATH}` — the latter form truncated PATH at user-manager start, which `pam_systemd` then propagated to PAM session env, breaking every subsequent login shell (`bat`, `dirname`, `cut` all unresolvable).

  Build infrastructure:
  - `mkosi.shared/sysext-build.sh::stage_sandbox_repos` extracted as a shared helper for the per-sysext `mkosi.sandbox/etc/yum.repos.d/*.repo` copy step. Fail-fast on missing repo files. Used by desktop / virt / nvidia postinsts.
  - `mkosi.postinst` postinst preset application loop now covers six myosi-* units (relabel × 2, depmod, firmware-reprobe, glib-schemas-compile, sysusers-after-sysext).
  - CI (the since-removed `ci/test-update-model.sh`) locked in: boot-ordering invariants (`DefaultDependencies=no` / `WantedBy=sysinit.target` for firmware-reprobe; no `Before=basic.target` for glib-schemas-compile), marker namespace (`/var/lib/myosi/.marks/*.done` only), `sysupdate` symlink presence, `MYOSI_SYSUPDATE_BIN` default, `command -v "$SYSUPDATE"` (not `[ -x ]`) in recipes, audit cmdline value.

  Documentation cleanups:
  - `.gitkeep` removed from `mkosi.extra/usr/share/myosi/` (was leaking into the deployed `/usr/share/myosi/.gitkeep`).
  - Top-level myosi directory survey: sealed/`/usr/{libexec,share,local/bin}`, writable/`/var/lib/myosi/.marks/`, ephemeral/`/run/myosi/{depmod,glib-schemas}`. Documented in this README's runbook section.

---

# Multi-disk storage runbook (appendix, ex-`install/partition-target.md`)

Detailed patterns for joining multiple encrypted disks into either
the existing `/var` btrfs pool or a separate pool. The basic single-
disk install path is covered under **Installing to real hardware**
above; this section adds the multi-disk operator workflows.

## 2. Multi-disk storage layouts

myosi's `/var` is a btrfs filesystem inside one LUKS container. It can be extended into a pool spanning multiple encrypted devices. Or you can create a separate pool mounted elsewhere (e.g. `/mnt/data`) for bulk storage.

Three helpers are shipped under `/usr/libexec/myosi/`:

| Helper | Purpose |
|--------|---------|
| `add-data-disk <device> [<label>]` | Encrypt a single extra disk and add it to the existing `/var` btrfs |
| `convert-pool <profile> [<mountpoint>]` | Rebalance an existing btrfs pool to a target chunk profile |
| `create-data-pool <mountpoint> <profile> <dev1> [<dev2> ...]` | Create a fresh encrypted btrfs pool spanning N disks, mounted somewhere |

### 2.1 Btrfs profile choices

| Profile | Behavior | Capacity | Redundancy | Min disks |
|---------|----------|----------|------------|-----------|
| `single` | Each chunk on one device; allocator picks where | sum | none | 1 |
| `raid0` | Stripe across devices | sum | none | 1 (any change makes it interesting at 2+) |
| `raid1` | Each chunk on 2 devices | sum / 2 | survives 1 disk loss | 2 |
| `raid10` | Stripe of mirrors | sum / 2 | survives 1 disk per mirror | 4 |
| `raid1c3` | Each chunk on 3 devices | sum / 3 | survives 2 disk losses | 3 |
| `raid1c4` | Each chunk on 4 devices | sum / 4 | survives 3 disk losses | 4 |

For mismatched disk sizes (e.g. 1 TB + 2 TB):
- `single` uses every byte; capacity = sum
- `raid0` only stripes up to the smaller capacity, then keeps using just the larger; allocator-dependent — usually suboptimal
- `raid1` capacity = smaller × 2 disks (1 TB usable from 1 TB + 2 TB pair)

### 2.2 Pattern A: extend `/var` with a second NVMe

Hosts with two NVMe drives (e.g. `/dev/nvme0n1` as the primary boot disk and `/dev/nvme1n1` as the second). To extend `/var` so user data lives across both:

```bash
# Boot from primary install (single-disk path in §1 above)
# Then on the running system:

# Add the second NVMe to /var
sudo /usr/libexec/myosi/add-data-disk /dev/nvme1n1 data-nvme1
#   Will prompt: confirm wipe, set LUKS passphrase, optional TPM2 enroll.

# Verify
sudo /usr/libexec/myosi/pool-status /var
#   Should show TWO devices in the pool.

# Use 'single' profile to keep full 3 TB usable capacity
sudo /usr/libexec/myosi/convert-pool single /var
```

Boot persistence: `/etc/crypttab` gets a new line for the second LUKS device automatically. On the next boot both devices unlock (passphrase or TPM2). `/var` mounts only after both LUKS volumes are open.

### 2.3 Pattern B: separate mirrored data pool for HDDs

Hosts with extra SATA HDDs for bulk storage (e.g. `/dev/sda` and `/dev/sdb`) intended for redundant bulk storage. Mounted at `/mnt/data`:

```bash
# Create a 2-disk raid1 pool (1 TB usable, mirrored)
sudo /usr/libexec/myosi/create-data-pool /mnt/data raid1 /dev/sda /dev/sdb
#   Confirms wipe, prompts for one LUKS passphrase per device,
#   writes 2 lines to /etc/crypttab + 1 line to /etc/fstab,
#   formats btrfs with raid1 data + metadata,
#   mounts at /mnt/data.

# Optional TPM2 enrollment for unattended unlock on each disk
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 /dev/sda
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 /dev/sdb

# Verify
sudo /usr/libexec/myosi/pool-status /mnt/data
```

Per-disk LUKS passphrases can be the same string (easier to remember) or distinct (slightly better blast-radius). Each one prompts separately during `create-data-pool`.

### 2.4 Pattern C: high-performance stripe (any host with 2 NVMes)

For a pure performance setup where you accept the risk:

```bash
sudo /usr/libexec/myosi/create-data-pool /mnt/fast raid0 /dev/nvme1n1 /dev/nvme2n1
```

`raid0` doubles read/write throughput at the cost of any single-disk failure destroying the whole pool. Use only for caches, build artifacts, swap-like workloads.

### 2.5 Adding a disk to a pool later

You can always add more disks to either `/var` or `/mnt/data` later:

```bash
# Existing pool (e.g. /var), add a third disk
sudo /usr/libexec/myosi/add-data-disk /dev/nvme2n1 data-nvme2
sudo /usr/libexec/myosi/convert-pool raid1 /var      # raise redundancy when you have ≥ 3 disks
# or
sudo /usr/libexec/myosi/convert-pool single /var     # keep maximum capacity
```

Capacity recomputes automatically. `convert-pool` rebalances live without unmounting.

### 2.6 Removing a disk from a pool

(Manual; no `just` recipe for this — risky enough to justify being explicit.)

```bash
# Move all data off the device
sudo btrfs device delete /dev/mapper/<label> /var

# After completion, close LUKS and remove crypttab entry
sudo cryptsetup luksClose <label>
sudo sed -i "/^<label>/d" /etc/crypttab
```

Reboot to confirm the device no longer appears in `/proc/mounts` / `btrfs filesystem show /var`.

## 3. Recovery scenarios

| Scenario | Recovery |
|----------|----------|
| LUKS passphrase lost, no TPM enrolled | Data on that LUKS volume is unrecoverable. Reinstall the affected disk. |
| LUKS passphrase lost, TPM2 enrolled | Boot proceeds (TPM unlocks). Reset passphrase: `sudo systemd-cryptenroll --password <luks-partition>`. |
| New base image update breaks boot | sd-boot boot-counter auto-rolls back after 3 failed boots. Manual: press space at sd-boot menu, pick the previous UKI. |
| One data disk in `/var` raid0 fails | Pool is dead. Mount with `degraded` to attempt rescue, restore from backups. |
| One data disk in `/var` raid1/raid10/raid1c3/raid1c4 fails | Boot with `rootflags=degraded` or add to the new disk's mount options, then `btrfs replace start` onto the new disk. |
| `/etc` drift causing weird state | Boot rescue, mount `/var`, `rm -rf /var/etc/*`, reboot. Image defaults apply fresh. |
| SecureBoot toggle invalidates TPM | TPM unlock fails → passphrase prompt. Re-enroll TPM2: `sudo systemd-cryptenroll --wipe-slot=tpm2 <luks> && sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 <luks>`. |

## 4. Verifying a clean install

After all setup steps, sanity checks:

```bash
# Sysext merged
sudo /usr/libexec/myosi/extension-list

# Verity root active
findmnt /
#   Should show /dev/mapper/root or similar with the verity device shown.

# All LUKS volumes unlocked
sudo dmsetup ls --target crypt

# Pool layout
sudo /usr/libexec/myosi/pool-status /var

# Boot-counter blessed (no rollback pending)
sudo systemctl status systemd-bless-boot.service

# Boot chain (if SecureBoot enabled)
mokutil --sb-state
sudo bootctl status

# Latest version is what you expect
cat /usr/share/myosi/version
```

---

# Signing keys (appendix, ex-`keys/README.md`)


Two keypairs sign every myosi build:

| Key | Algorithm | Validity | Use |
|-----|-----------|----------|-----|
| `boot.key` / `boot.crt` | RSA-4096 SHA-384 | 5 years | sd-boot binary, UKIs, MOK enrollment |
| `image.key` / `image.crt` | RSA-4096 SHA-384 | 5 years | dm-verity root hashes, sysext signatures |

`image.key` is RSA-4096 because `systemd-repart` wraps the dm-verity root hash in PKCS#7/CMS, and OpenSSL 3.x refuses to sign PKCS#7 with EdDSA keys.

## Layout

```text
keys/
├── boot.key
├── boot.crt
├── image.key
├── image.crt
└── OVMF_VARS-enrolled.fd
```

All key material is gitignored. The same paths are used for local and CI builds; the source of the files determines the trust context.

- Local builds populate `keys/` with `./scripts/generate-keys.sh`.
- CI builds decode `MYOSI_*` GitHub Secrets into `keys/`.
- The image ships only the public certs at `/usr/share/myosi/keys/` for manual MOK enrollment. Each cert is shipped twice: `boot.crt` / `image.crt` in PEM form (for `openssl x509 -text` and human inspection) and `boot.der` / `image.der` in DER form (which is what `mokutil --import` actually requires — it rejects PEM). The base image carries `openssl` too if you need to roll your own conversion.

## Generating keys

```bash
./scripts/generate-keys.sh
```

What the script does (updated 2026-06-03):

1. Generates `boot.key`/`boot.crt` and `image.key`/`image.crt` (RSA-4096 SHA-384) if they don't exist. Reuses existing keys otherwise.
2. Locates a **4 MiB** OVMF varstore template (matches `OVMF_CODE_4M.secboot.qcow2` which modern qemu q35+smm consumes). On Fedora 44 the 4 MiB variant ships only as `.qcow2`, so the script converts via `qemu-img convert -O raw` to a usable `.fd`. Falls back to the 2 MiB variant last — a 2 MiB varstore paired with the 4 MiB firmware silently rejects all stored variables and OVMF falls back to "No bootable option."
3. Enrolls keys via the `virt.firmware` Python library directly (not the `virt-fw-vars` CLI):
   - PK / KEK / db ← `boot.crt`
   - db ← `image.crt` (so the kernel's `.platform` keyring contains it post-boot for verity validation)
   - MokList ← `boot.crt` (so shim trusts our locally-signed UKIs without manual mokutil enrollment)
   - KEK ← Microsoft KEK keys (`add_microsoft_kek_keys('all')`)
   - db ← Microsoft UEFI CA + Windows PCA (`add_microsoft_keys('all')`)
4. `enable_secureboot()` sets the SB-enabled flag.

The Microsoft keys are required because CI builds use `ShimBootloader=signed` — Fedora's MS-signed shim validates against Microsoft UEFI CA in db. Without them OVMF rejects the shim with `Access Denied`.

Requirements on the host:

```bash
sudo dnf install -y python3-virt-firmware qemu-img edk2-ovmf openssl
```

## Preparing CI secrets

Generate or choose the signing keypair, then base64-encode the four files for GitHub Actions secrets:

```bash
base64 -w0 boot.key   > MYOSI_BOOT_KEY.b64
base64 -w0 boot.crt   > MYOSI_BOOT_CRT.b64
base64 -w0 image.key  > MYOSI_IMAGE_KEY.b64
base64 -w0 image.crt  > MYOSI_IMAGE_CRT.b64
```

Store the private keys in an encrypted backup outside the repository.

## Rotation

At year 4.5 or after compromise:

1. Generate a new keypair.
2. Add it to GitHub Secrets under temporary names.
3. Build one transition release and enroll the new certs on each host with `mokutil --import /usr/share/myosi/keys/{boot,image}.der`.
4. Switch CI to the new secrets.
5. Retire the old secrets.

## Enrollment on a SecureBoot-disabled host

mokutil still works. Shim's MokManager UI runs at boot whenever an enrollment is queued, regardless of SecureBoot state. Sequence:

```bash
sudo mokutil --import /usr/share/myosi/keys/boot.der /usr/share/myosi/keys/image.der
# set a one-time MOK enrollment password when prompted
sudo reboot
# at the MokManager menu: Enroll MOK → Continue → Yes → enter the password → Reboot
sudo keyctl list %:.machine   # verify the certs are loaded
```

On Fedora 44 the `.machine` keyring is linked into the secondary keyring chain used by dm-verity, so `.machine`-enrolled `image.crt` satisfies sysext signature validation even with SB off. If your kernel does NOT wire `.machine` to verity (older or vanilla configurations), rebuild sysexts unsigned by switching `mkosi.shared/sysext.conf` from `Verity=signed` to `Verity=yes` — Merkle-tree integrity stays, the PKCS7 sig is dropped, no keyring lookup is needed.
