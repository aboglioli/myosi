# myosi

Personal atomic, immutable Linux distribution built from raw mkosi + systemd primitives. Signed dm-verity erofs root, A/B sysupdate slots, signed sysexts for optional userspace features (kernel modules included), and an `/etc` assembled at boot as an overlay — verity-baked factory defaults underneath, a btrfs subvolume on the encrypted data-luks pool holding only what this host changed. Fedora 44 base. No bootc, no ostree, no rpm-ostree.

The base image is the same on every host. Hostname and local tweaks live in the overlay upper at `/.etc/etc` on `data-luks`; every path nobody touched shows through from the verity-baked `/usr/share/factory/etc` factory tree and therefore tracks the image across upgrades. Optional features (desktop, containers, virt, firmware, NVIDIA Turing+, NVIDIA Pascal/Maxwell/Volta legacy, OpenZFS) are added per host by enabling signed sysexts on top of the slim base. Every kernel module shipped in a sysext is signed with `boot.key` so it passes `module.sig_enforce=1` at load.

**See the Design notes and Multi-disk storage runbook appendices below for full architecture, rationale, multi-disk patterns, and milestones.**

---

## Why a second OS?

`myos` (the sibling project) is a bootc/ostree image. It works. It's complex underneath: bootc + ostree + composefs + rpm-ostree all interacting. `myosi` rebuilds the same idea directly on top of upstream systemd primitives:

| Concern | myos (bootc) | myosi (mkosi) |
|---------|--------------|---------------|
| Image format | OCI container | signed disk image (raw) |
| Root integrity | composefs (fs-verity) | dm-verity over erofs (signed Merkle tree) |
| Atomic updates | `bootc upgrade` (OCI pull) | `systemd-sysupdate` (signed artifact pull) |
| `/etc` model | layered via ostree 3-way merge | overlayfs assembled pre-pivot: `lowerdir=/usr/share/factory/etc` (verity-baked), `upperdir=/.etc/etc` (btrfs subvol on `data-luks`) |
| Boot chain | shim → GRUB → BLS entries | shim → sd-boot → signed UKI |
| Per-host config | host-specific image variant | the `/etc` overlay upper on `data-luks` |
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
│                       sysroot-.etc.mount → /sysroot/.etc       │
│                       myosi-etc-prepare  → mkdir + label layers │
│                       sysroot-etc.mount  → overlay onto /etc    │
│                       → switch_root                             │
│                  └─ real root systemd:                          │
│                       var.mount (gpt-auto from Type=var,        │
│                                  DefaultSubvolume=/var)         │
│                       home.mount + srv.mount (btrfs subvols)    │
│                       systemd-sysext → merge /usr extensions    │
└─────────────────────────────────────────────────────────────────┘
```

**Why repart runs in the initrd:** `systemd-repart.service` runs after `sysroot.mount` in the initrd, reads `/usr/lib/repart.d/*.conf` from the initrd cpio image, and creates missing partitions (root-B, verity-B, verity-sig-B, data-luks) or grows the existing data partition to fill the disk. The initrd repart definitions are copied from `mkosi.extra/usr/lib/repart.d/` via `ExtraTrees=`. Running repart in the initrd ensures that `/dev/mapper/data` has full capacity, and that the `/var` + `/etc` subvolumes exist on it, before `sysroot-.etc.mount` fires (in the initrd) and `var.mount` is auto-generated (in the main system) — no manual `cryptsetup resize` or `btrfs filesystem resize max` step needed on first boot.

**Why there is no `/etc/fstab` or `/etc/crypttab`:** The sealed erofs `/etc` is wiped after its factory contents are snapshotted to `/usr/share/factory/etc`, leaving an empty directory for `sysroot-etc.mount` to mount the overlay onto. Static crypttab/fstab would be wrong for multi-disk hosts (global PARTLABEL selection races with attached myosi disks) and cannot handle the `data-N` pool members. The initrd `myosi-data-attach` service discovers and unlocks the primary data partition + any `data-N` pool members directly; `sysroot-.etc.mount` + `myosi-etc-prepare.service` + `sysroot-etc.mount` assemble `/etc` before pivot; explicit `var.mount`, `home.mount`, and `srv.mount` units mount the sibling subvols in the main system (each with `BindsTo=dev-mapper-data.device`, `Options=defaults,noatime,compress=zstd:3,subvol=/<name>`).

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
| `virt_VERSION_ARCH.raw` | Sysext: libvirt, qemu, vfio, virt-manager |
| `nvidia_VERSION_ARCH.raw` | Sysext: NVIDIA `current` (595.x open kernel modules, Turing+ — RTX 16xx/20xx/30xx/40xx/50xx). All `nvidia*.ko` signed with `boot.key`. |
| `nvidia-580xx_VERSION_ARCH.raw` | Sysext: NVIDIA `580xx` legacy proprietary modules (Maxwell / Pascal / Volta — GTX 9xx/10xx, Titan V). All `nvidia*.ko` signed with `boot.key`. |
| `zfs_VERSION_ARCH.raw` | Sysext: OpenZFS (`zfs-2.4.2` today) — `zfs.ko` + `spl.ko` signed with `boot.key`, plus userspace (`zfs`, `zpool`, `zed`, libraries, `zfs-dracut`, `python3-pyzfs`). Built from the upstream tarball, no RPMFusion / zfsonlinux.org repo dependency. |

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
│   ├── etc/                 # /etc baseline -> snapshotted to /usr/share/factory/etc (the overlay lower)
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
| `/usr/share/myosi/` | All myosi-shipped data: signing keys, version metadata, baseline sysext images, baked SSH keys (if provided). Verity-immutable. | Image-coupled. Changes atomically with each image upgrade. |
| `/usr/share/myosi/extensions/` | Baseline sysext `.raw` files that ship inside the image (none currently; infrastructure kept for future baselines). NOT a path systemd-sysext discovers from — see below. | Image-coupled. |
| `/usr/lib/extensions/` | Documented by systemd as a sysext location but in practice systemd-sysext does NOT scan it for discovery on F44 / systemd 259. Do not bake new sysexts here. | (avoid) |
| `/etc` | overlayfs, assembled pre-pivot by three initrd units. Not a stored filesystem — it is the union of the two rows below. | Operator-mutable. |
| `/usr/share/factory/etc/` | **The overlay lower.** The verity-baked factory `/etc` tree; `mkosi.finalize` snapshots the build-settled `/etc` here then wipes the sealed-root `/etc` mountpoint. Rotates atomically with the image, so any path this host has not touched follows the image across upgrades. | Image-coupled. |
| `/.etc/etc` | **The overlay upper** — inside the `/etc` btrfs subvolume on `data-luks`, mounted at `/.etc`. Contains exactly what this host changed: modified files, host-only files, and 0:0 character devices where a factory file was deleted. `myosi etc-list` reads it. | Operator-mutable. |
| `/.etc/.work` | overlayfs workdir. Must be a sibling of the upper inside the same subvolume — see the `/etc` overlay section for the kernel rules that force this. | Internal. |
| `/var/lib/myosi/extensions/` | Versioned sysext store, filled by sysupdate (`InstancesMax=2`: current + previous generation). NOT a sysext discovery path. | sysupdate-managed. |
| `/var/lib/extensions/` | The discovery path systemd-sysext actually scans. `sysext-select` links exactly ONE version per sysext here (from the store or the baked baselines) — the one matching the booted `IMAGE_VERSION`. Operator-dropped regular files override selection for their sysext name. | Selector-managed + operator-mutable. |
| `/etc/extensions/`, `/run/extensions/` | Additional sysext discovery paths (rare). | Operator-mutable. |
| `/srv`, `/mnt` → `var/mnt` | `/srv` is a dedicated btrfs subvolume from `data-luks`; `/mnt` is symlinked into writable `/var`. | `/srv` and `/mnt` targets are operator-mutable. |
| `/var/lib/machines/` | Per-machine btrfs subvolumes for `systemd-nspawn` containers managed by `machinectl`. | Operator-mutable. |
| `/usr/libexec/myosi/` | Shipped helper scripts (`sysext-modules-refresh`, `homed-user-provision`, `sysext-select`, `install`, `lib.sh`). | Image-coupled. |

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

myosi handles this with a store + selector model:

1. **Image-baked baselines** live at `/usr/share/myosi/extensions/`
   (verity-immutable, atomic swap on image upgrade).
2. **The sysupdate store** at `/var/lib/myosi/extensions/` holds
   VERSIONED raws (`<name>_<VER>_<ARCH>.raw`, `InstancesMax=2` — the
   current and the staged/previous generation side by side). Both dirs
   are outside sysext's scan paths on purpose.
3. **`sysext-select`** runs as `ExecStartPre=` of
   `systemd-sysext.service` on every boot and every `systemd-sysext
   refresh`. Per sysext name it links exactly ONE raw into
   `/var/lib/extensions/`: the version matching the booted image's
   `IMAGE_VERSION`, falling back to the newest present (with a journal
   warning). Stale managed symlinks are pruned.
4. **Operator-dropped regular files** in `/var/lib/extensions/` are
   never touched and suppress selection for that sysext name.

This is what makes sysext updates A/B-shaped: sysupdate stages the new
generation's raws next to the current ones, the reboot into the new
root slot selects the new sysexts, and a rollback (sd-boot menu or
boot-counting) into the old slot re-selects the old sysexts — kernel
modules always match the booted kernel.

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

### The /etc overlay

`/etc` is not stored anywhere. It is assembled before the pivot from two
directories:

```
lowerdir  /usr/share/factory/etc   the image's defaults, verity-baked
upperdir  /.etc/etc                what this host changed
workdir   /.etc/.work              overlayfs scratch space
```

`/.etc` is the `/etc` btrfs subvolume on `data-luks` — the same subvolume
as before, holding the two overlay layers instead of `/etc` itself. Its
mountpoint is a dot-prefixed empty directory baked into the sealed image
by `postinst-common.sh`, because the runtime root is read-only erofs and
nothing can create it at boot.

The consequence that matters: **a path nobody touched keeps following the
image.** New factory files appear on upgrade, changed defaults apply. A
path this host *has* touched is copied up into `/.etc/etc` and stays
yours. So the upper is the complete, exact list of local changes —
`myosi etc-list` reads it directly, with nothing to diff and nothing to
remember after an upgrade.

**Three units, no new scripts.** Assembling `/etc` is entirely declarative:

| Unit | Does |
|---|---|
| `sysroot-.etc.mount` | mounts `subvol=/etc` at `/sysroot/.etc` |
| `myosi-etc-prepare.service` | `mkdir` the two layer dirs, stamp `etc_t` on both |
| `sysroot-etc.mount` | mounts the overlay onto `/sysroot/etc` |

The middle one is three `ExecStart=` lines, not a shell script. Its
labelling step is not optional: overlayfs takes the merged `/etc`'s own
directory label from the upperdir, and files *created* in `/etc` inherit
from it. With an unlabeled upper, `/etc` comes up `unlabeled_t` and
everything first written at runtime — machine-id, ssh host keys,
NetworkManager connections — lands `unlabeled_t` under enforcing. Both
outcomes were checked by mounting the overlay each way. Stamping before
the mount also avoids the first-boot relabel race described below.

**Why the initrd.** PID 1 reads `/etc/selinux/config` and
`/etc/systemd/system.conf` synchronously at startup, so no unit in the
real system can mount over `/etc` in time. myosi's two-stage boot already
provides a pre-PID-1 window; the sibling `mybox` project has to ship a
PID 1 `preinit` shim for exactly this reason.

**Why the subvolume root is not the upperdir.** Two kernel rules, both
verified, both load-bearing:

1. `workdir` and `upperdir` must live under the **same mount**, or
   `mount(2)` returns `EINVAL`.
2. On btrfs they must live in the **same subvolume**. Different
   subvolumes under one mount pass the mount check and then fail *every
   copy-up* with `EXDEV` — a clean mount that breaks at the first write
   to a factory file, which is the worst possible failure shape.

Neither may contain the other. So the upper has to be a child of the
mounted subvolume with the workdir as its sibling, which is why the
subvolume mounts at `/.etc` and the layers sit inside it.

**Why this is not the overlay that was retired.** The earlier attempt put
the upper at `/var/etc`, which forced `/var` to mount before `/etc`
(impossible — `var.mount` is read from `/etc`), left PID 1 holding the
overlay open so `var.mount` logged FAILED at shutdown, and cached the
upper's SELinux context before the first-boot relabel could fix it. The
current shape avoids all three: `/var` is not involved; neither mount is
owned by a unit in the real system (both are inherited across the pivot
and adopted from `/proc/self/mountinfo`, exactly as `/etc` already was),
so systemd never tries to stop them and `systemd-shutdown` handles them
in its final pass; and `etc_t` is stamped before the overlay mounts, with
no first-boot relabel in the picture at all.

**Sharp edges:**

- Copy-up is per-file and permanent until reset. A daemon that rewrites a
  factory file for its own reasons pins that file's content even if the
  bytes are unchanged. `myosi etc-prune` finds those.
- Deleting a factory file leaves a whiteout, and `rm -rf` on a factory
  directory sets `trusted.overlay.opaque` — the whole factory subtree
  stays hidden even if the image later adds files to it.
- **The upper of a mounted overlay should not be edited.** The kernel
  makes no promise about the view until the overlay is re-established,
  and only the initrd can re-establish `/etc`. `myosi etc-reset` and
  `etc-prune` therefore both end with "reboot to apply".
- `confext` is still dormant, and now overlaps more directly: a confext
  layer would stack its own overlay over this one and shadow operator
  writes. Reconciling the two still needs a design pass.

### Boot path summary

```
firmware → shim → systemd-boot → UKI (signed; kernel + initrd + cmdline + os-release)
   initrd: systemd-veritysetup → mount root RO
           systemd-repart → create missing partitions + grow data-luks to fill disk
                          + create /var and /etc subvolumes inside data-luks btrfs
           myosi-data-attach → find Type=var on same disk as root, unlock as /dev/mapper/data
                              + unlock any data-N pool members from any disk
                              + btrfs device scan to register all pool members
           sysroot-.etc.mount    → /sysroot/.etc (btrfs subvol=/etc)
           myosi-etc-prepare     → mkdir /.etc/{etc,.work}, stamp etc_t
           sysroot-etc.mount     → overlay onto /sysroot/etc
                                   lower=/usr/share/factory/etc
                                   upper=/.etc/etc  work=/.etc/.work
           → switch_root
   real root: var.mount + home.mount + srv.mount (explicit units, all
                BindsTo=dev-mapper-data.device, Before=local-fs.target)
              systemd-sysext → merge /usr extensions
```

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
   `gpasswd -a <user> <group>`. The membership lands in
   `/etc/group` (persistent btrfs subvol on data-luks) and
   is picked up at next login. When the instance name doesn't own the
   record's UID, the guard retargets binding to the user that actually
   does — so a host that created its own primary user still gets bound.

4. The binder runs at two trigger points: at boot via
   `myosi-homed-user@<you>.service` (templated unit, ordered
   After=systemd-homed.service so the varlink interface is up) AND
   from `refresh_sysext` in `lib.sh` (after every live
   `systemd-sysext refresh`, which starts every **enabled** instance —
   it must not hardcode one, or it would materialize a user on a host
   that deliberately never enabled the unit).

   **The instance is not enabled by default.** Run `systemctl enable
   --now myosi-homed-user@<you>.service` once, post-install — see
   [Post-installation](#post-installation). Until then, sysext group
   drop-ins are installed but never bound to anyone.

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

### Generators run before every mount — nothing may point into `/home`

systemd runs unit generators at the very start of the boot transaction:
before `local-fs.target`, before any `.mount` unit, and long before
`systemd-homed` has activated anybody's home. Whatever a generator reads
must already be there — on myosi the verity root or the `/etc` subvol
(mounted in the initrd), never `/home`, `/srv` or `/var`.

The failure is silent, which is what makes it a footgun. A symlink from a
generator input directory into a home directory does not resolve at
generator time, and the unit it should have produced never exists:

```
quadlet-generator[1341]: error loading "/etc/containers/systemd/foo.container",
                         open ...: no such file or directory
```

`systemctl status foo.service` then reports **`Unit foo.service could not
be found`** — not a failed unit, no unit at all. The usual "cure" is a
manual `daemon-reload` after login, because by then the home is mounted;
that is the symptom, not a fix.

- Install system quadlets into `/etc/containers/systemd/` as **real files**
  (`install -m0644`), never symlinks into a tree under `/home`.
- Same for any generator input: `.container`/`.network`/`.volume` files,
  `/etc/systemd/system-generators`, fstab fragments.
- No unlock mechanism changes this — TPM2 on the disk, an unlocked homed
  home, `enable-linger`: generators precede mounting entirely. (And homed
  has no TPM2 support; see the homed section.)
- For *user*-scope quadlets the sibling rule already applies: keep their
  data outside the encrypted home (`/srv/users`,
  `/var/lib/containers/users`).

Run the generator by hand to see exactly what systemd would get, including
the `*.target.wants/` symlinks that decide whether a unit starts at boot:

```bash
sudo /usr/lib/systemd/system-generators/podman-system-generator /tmp/g /tmp/g /tmp/g
find /tmp/g
```

### Versioned artifact paths

| Where | Convention |
|---|---|
| `/usr/share/myosi/version` | Image metadata (name, version, build date, git commit, Fedora release, kernel uname). NOT a bootc reference — myosi assembles from RPMs directly. |
| `/efi/EFI/Linux/myosi_<VER>_<ARCH>.efi` | UKIs. `InstancesMax=2` keeps two on the ESP for rollback. |
| `/var/lib/myosi/extensions/<name>_<VER>_<ARCH>.raw` | versioned sysext store (sysupdate target, current + previous generation). |
| `/var/lib/extensions/<name>_<VER>_<ARCH>.raw` | sysext discovery — a `sysext-select`-managed symlink into the store/baselines, or an operator-installed regular file. |

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
  failures because READY=1 fires before ExecStartPost runs). **No
  instance is enabled by default** — the image ships no interactive user
  (see [Post-installation](#post-installation)). The operator enables
  `myosi-homed-user@<you>.service` post-install for group binding, or a
  rebuilt image pre-bakes one by shipping
  `/usr/share/myosi/users/<name>.user` plus a
  `multi-user.target.wants/myosi-homed-user@<name>.service` symlink via
  `mkosi.local.conf` `ExtraTrees=`.
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
- `/etc` is an overlay again, but with the layers inside the `/etc`
  subvolume mounted at `/.etc` instead of at `/var/etc`. The three
  problems that killed the first attempt were all properties of the
  `/var` location, not of overlayfs: `/var` cannot mount before `/etc`,
  PID 1 pinned `var.mount` open at shutdown, and the upper's SELinux
  context was cached before the first-boot relabel. The current shape
  keeps `/var` out of the boot path, leaves both mounts unowned by any
  unit in the real system, and stamps `etc_t` before mounting. The
  plain-subvolume model it replaces froze `/etc` at first boot, which is
  how this fleet ended up without `/etc/myosi/users/`.
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
- homed's logout shrink of a LUKS home is controlled by
  `--auto-resize-mode`, **not** by `--luks-offline-discard`. The two are
  separate gates and an earlier round of this doc conflated them; setting
  only the discard flag left a 20 s+ minimize on every shutdown. See
  [the sizing policy](#3a1-user-management-with-systemd-homed).

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
- `myosi-data-attach.service` unlocks `/dev/mapper/data` (key-file first, then TPM2/passphrase fallback) + unlocks present `data-N` pool members + runs `btrfs device scan`. It does **not** mount anything
- `sysroot-.etc.mount`, `myosi-etc-prepare.service` and `sysroot-etc.mount` mount the `/etc` subvolume at `/sysroot/.etc`, create and label the overlay layers inside it, and mount the overlay onto `/sysroot/etc`, all before pivot (`/var`, `/home`, `/srv` mount post-pivot via the explicit `var.mount`, `home.mount`, `srv.mount` units — not gpt-auto). On a fresh host the upper is empty, so `/etc` **is** the factory tree — there is no first-boot seeding step
- `systemd-firstboot` (locale/timezone/etc pre-baked, no-op)

**No interactive user is created.** The image ships none on purpose — see
[Post-installation](#post-installation) for why and what to do next.

### Step 3 — Post-install runbook

Run these steps after the first successful boot. The base image is identical on every host; this section turns it into a usable machine by setting local credentials, growing mutable storage, enrolling trust anchors, and enabling host-specific extensions.

<a id="post-installation"></a>
#### 3a. Post-installation — create your user, then lock root

**The image ships no interactive user.** `myosi-homed-user@.service` is
present but **disabled**, and `/usr/share/myosi/users/user.user` is only an
example. The single credential in the image is the console bootstrap:
**`root` / `changeme`**.

**Why no default user:** a public image would have to pick a generic name
(`user`), and **systemd 259 cannot rename a homed user** — there is no
`homectl rename`. The name is embedded in the signed user record, the
record filename, `homeDirectory`, the `/home/<name>.home` image, the inner
btrfs subvolume and label, the LUKS header's embedded identity, and the
blob dir. "Renaming" is really create-new → copy → delete-old, which needs
2× the space and re-encrypts everything. Cheap on day one, painful at 50 GB.
So you pick the real name once, here.

**Why a known root password is acceptable:** it is **console-only**. sshd is
`AuthenticationMethods publickey` with `PasswordAuthentication no` and
`PermitRootLogin prohibit-password`, so it grants nothing remotely — an
attacker needs physical access. It is also meant to be destroyed in step 4.
For fleets, bake your own hash over `etc/shadow` via `mkosi.local.conf`
`ExtraTrees=`.

**Write a user record, then enable its unit.** That is the whole flow — the
record is a plain file on the writable `/etc` subvolume, so this needs no
rebuild and no credentials:

```bash
# 1. Log in at the CONSOLE as root / changeme.

# 2. Describe YOUR user. Pick the real name now — it cannot be changed
#    later. uid 1000 makes it the primary user. Full field list and a
#    commented example live in /etc/myosi/users/README.
cat >/etc/myosi/users/<you>.user <<'EOF'
{
    "userName": "<you>",
    "uid": 1000,
    "gid": 1000,
    "realName": "<Your Name>",
    "homeDirectory": "/home/<you>",
    "shell": "/usr/bin/fish",
    "memberOf": ["wheel", "video", "render", "input", "kvm"],
    "preferredLanguage": "en_US.UTF-8",
    "service": "io.systemd.Home",
    "enforcePasswordPolicy": false
}
EOF

# 3. Enable the instance. This CREATES the user (LUKS home, correct storage
#    flags, SELinux defcontext) and binds it to any sysext-declared groups.
#    Idempotent — re-running it later only re-checks group membership.
systemctl enable --now myosi-homed-user@<you>.service
homectl passwd <you>                  # rotate off the `changeme` bootstrap

# 4. Verify you can log in as <you> on another TTY (Ctrl-Alt-F2) BEFORE
#    this next step — locking root with no working user leaves you with
#    only the USB installer as a way back in.
passwd -l root

# 5. Name the host.
hostnamectl hostname <hostname>
```

Leaving the instance enabled is what keeps your groups in sync: every
`myosi extension-enable` re-runs it, so a sysext that introduces a new group
binds it on the spot.

Step 3 also allocates the `/etc/subuid` + `/etc/subgid` ranges rootless
podman, distrobox and incus need. Nothing else maintains those files — a
homed record has no field that feeds them, and `usermod --add-subuids`
refuses homed users because they are not in `/etc/passwd`. The helper takes
the first free `1000000`-wide gap at or above `100000`, so it is safe on a
pre-existing file with custom entries; an existing entry for your name is
left alone, and if nothing fits it says so rather than writing a bad range.
Verify with:

```bash
grep "^<you>:" /etc/subuid /etc/subgid
podman unshare cat /proc/self/uid_map     # as <you>, after logging in
```

**Alternative — create it by hand.** If you would rather not keep a record
file, `homectl create` does the same thing; these are the flags the helper
would have applied (`defcontext=` is REQUIRED, or SELinux denies
sudo/sshd/keyring — see 3a.1 for each one's rationale):

```bash
homectl create <you> \
    --uid=1000 --real-name="<Your Name>" --member-of=wheel \
    --shell=/usr/bin/fish --storage=luks --disk-size=50G --fs-type=btrfs \
    --luks-discard=yes --luks-offline-discard=no --auto-resize-mode=grow \
    --luks-extra-mount-options=defcontext=system_u:object_r:user_home_dir_t:s0
```

Enable the unit afterwards anyway — with no record file it skips creation
and does group binding only, which is exactly what you want at that point.

**Group memberships from sysexts** (`libvirt`, `incus-admin`, …) come from
`/usr/share/myosi/user-groups.d/*.conf`, which the same unit reads in its
second phase. That is why step 3 leaves the instance enabled rather than
just running it once.

Enabling works even though `/usr` is a read-only erofs image: `systemctl enable`
writes a symlink into `/etc/systemd/system/…​.wants/` pointing *at* the unit
in `/usr`. `/etc` is a writable btrfs subvolume on data-luks, so the
enablement also **survives A/B image updates** — the root slot rolls over,
`/etc` does not. (Enabling a **sysext-provided** unit this way is not safe:
the symlink dangles whenever that sysext is disabled. Those use `Upholds=`
drop-ins instead — see "Enabling units without presets".)

**Creation is driven entirely by the record file.** The helper searches two
places, in order:

1. `/etc/myosi/users/<name>.user` — writable, operator-authorable
   post-install, survives A/B image updates. This is the one you use
2. `/usr/share/myosi/users/<name>.user` — baked, read-only erofs, so
   operators cannot add records here. Only `user.user` ships, as an example

With a record for `<name>`, enabling the instance creates the user and binds
groups. With no record it binds groups only — so `systemctl enable --now
myosi-homed-user@<you>.service` on a name you never wrote a file for will
not conjure a user. (`@user` is the one exception: `user.user` is baked, so
enabling that instance does create the generic user.)

Editing the record later does **not** update an existing user — creation is
one-shot, gated on `homectl inspect`. Use `homectl update` for that.

To pre-bake a user on a rebuilt image instead, ship
`usr/share/myosi/users/<you>.user` plus a
`multi-user.target.wants/myosi-homed-user@<you>.service` symlink through a
private `mkosi.local.conf` `ExtraTrees=` overlay. Do **not** additionally
enable `@user`: both instances claim UID 1000 and start in parallel, so
which one wins is a race. If UID 1000 is already taken by someone else the
helper never creates — it retargets group binding to the actual owner.

**What else is operator-enabled?** Almost nothing — the image is opinionated
and presets cover the rest:

| Unit | State | Enable when |
|---|---|---|
| `myosi-homed-user@<you>.service` | disabled | You want sysext group bindings kept in sync (above) |
| `systemd-homed-firstboot.service` | disabled | You'd rather be prompted for a user on first boot, or drive it with a `home.create.<name>` credential. Blocks unattended installs if it prompts |
| `bootc-fetch-apply-updates.timer` | disabled **on purpose** | Never — it conflicts with sysupdate-driven UKI rollover |

Sysexts are **not** managed with `systemctl` — use `myosi extension-enable
<name>` (see 3e). Updates are deliberately manual (`myosi update`); there is
no auto-update timer. Only `fstrim.timer` and
`systemd-tmpfiles-clean.timer` run periodically.

#### 3a.1. User management with systemd-homed

Interactive users on myosi are owned by `systemd-homed`. The user
record ships as a declarative JSON file at
`/usr/share/myosi/users/<name>.user` (UID, shell, supplementary
groups, hashed password — NO secret/storage/diskSize, those are CLI
flags). `myosi-homed-user@<name>.service` runs
`/usr/libexec/myosi/homed-user-provision <name>` on first boot,
which calls `homectl create --identity=<file> --storage=luks
--disk-size=50G --luks-discard=yes --luks-offline-discard=no
--auto-resize-mode=grow --luks-extra-mount-options=defcontext=...` with the
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
50 GiB default). Defence in depth on top of data-luks: data-luks
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

**Sizing policy — `--luks-discard=yes --luks-offline-discard=no
--auto-resize-mode=grow`:** three mechanisms, easily confused. Two are
discard flags; the one that actually resizes the home is neither of them.
In `systemd-homework` they are three independent gates, all evaluated on
the same logout path (`src/home/homework.c:1014-1028`, systemd 259).

*Online* discard (`--luks-discard=yes`) is the `discard` mount option on
the inner btrfs. It reclaims space continuously while the user is logged
in, through the whole stack: inner btrfs → dm-crypt (`allow_discards`) →
loop device → `FALLOC_FL_PUNCH_HOLE` on the `.home` file → outer btrfs
frees the extents. A 50 GiB home holding 9 GiB really occupies ~9 GiB of
data-luks. This is what keeps the sparse image honest — keep it on.

*Offline* discard (`--luks-offline-discard=no`; systemd's default is
**on**) is a plain FITRIM at logout, in `home_trim_luks()`. We turn it
off because it reclaims almost nothing online discard has not already
reclaimed — it only truncates the tail of an already-hole-punched sparse
file. Turning it off also makes homed `fallocate()` the image instead, so
the file's *apparent* size stays at the full `--disk-size` (see the
sparse-copy warning in Troubleshooting). `fstrim.timer` (weekly, enabled
by default) remains the backstop.

*Auto-resize mode* (`--auto-resize-mode=grow`) is the one that resizes.
**It is not gated on either discard flag** — a common and expensive
misreading. `user_record_auto_resize_mode()` (`src/shared/user-record.c:2152`)
returns `shrink-and-grow` for **any** `--storage=luks` record that does
not set the field, and that mode makes `home_auto_shrink_luks()` minimize
the entire stack at logout — shrink btrfs to its floor, shrink LUKS,
truncate the image file, rewrite the partition table — then grow it all
back at the next login. Two problems:

1. **It stalls shutdown.** btrfs can only shrink online, via a slow
   relocate loop. A 50 G → 12 G minimize took 21 s of an otherwise 2 s
   shutdown on real hardware (NVMe, AES-NI).
2. **It corrupts the home's size when interrupted.** `systemd-homed`
   waits a hardcoded 30 s for the worker during shutdown, then `SIGKILL`s
   it — homed-internal, *not* tunable via `TimeoutStopSec=`. If the kill
   lands mid-relocate, btrfs ends up shrunk (~13 G) inside a still-50 G
   LUKS device. On the next boot homed's grow path compares the *image
   file* size against the record's `diskSize`, sees 50 G == 50 G, logs
   `Image size already matching, skipping operation`
   (`homework-luks.c:3245`), and never asks btrfs — so `df` reports a
   ~13 G home, permanently, until someone runs `btrfs filesystem resize
   max` by hand. Observed on 2 of 6 consecutive boots.

`grow` rather than `off`: it suppresses the logout shrink identically,
while keeping `home_auto_grow_luks()` on the activation path
(`homework-luks.c:1593`) as a repair route for an image that is already
too small — a restored backup, or a home shrunk before this setting was
applied. Once nothing shrinks the image, that path is a no-op that logs
`Image size already matching` and returns before touching the device.
Use `off` only if you want homed to never touch the geometry unasked.

Symptom to recognize: `btrfs filesystem usage $HOME` shows a large
`Device slack:` value. Repair is online and non-destructive:

```bash
sudo btrfs filesystem resize max /home/<user>
homectl update <user> --auto-resize-mode=grow    # stop it recurring
```

Note that `--luks-offline-discard=no` alone does **not** stop it: the
FITRIM disappears from the logout path, the minimize does not. The
giveaway in the journal is a `Ready to resize image size 50G → 11.9G`
line at deactivation on a record that already reports
`LUKS Discard: online=yes offline=no`.

**First-boot flow:**

1. `myosi-sshd-hostkeys.service` generates rsa+ecdsa+ed25519 host keys
   sequentially in `/etc/ssh/` (preserved from the overlay era as
   belt-and-suspenders; the /etc subvol is a plain filesystem so the
   parallel `sshd-keygen@*` race no longer applies, but the
   sequential generator costs nothing and keeps logs readable).
2. `systemd-homed.service` starts. **No user is provisioned** —
   `myosi-homed-user@.service` ships disabled, so nothing calls
   `homectl create`. (On images that pre-bake an identity via a private
   overlay, the enabled `@<name>` instance runs `homed-user-provision
   <name>` here, seeding the LUKS keyslot from the `MYOSI_BOOTSTRAP_PASSWORD`
   env default via `PASSWORD`/`NEWPASSWORD`.)
3. Operator logs in at the console as `root` / `changeme`, runs
   `homectl create <you> --uid=1000 ...` to create the real user, then
   `passwd -l root`. See [Post-installation](#post-installation).
4. (Optional) Operator runs `sudo loginctl enable-linger <you>`
   if they want rootless quadlets to keep running across reboots.
   Linger is NOT enabled by default, and on a LUKS-backed homed user it
   cannot give you an unlocked home at boot. **systemd-homed has no TPM2
   support** (no `--tpm2-device`; it offers password, PKCS#11, FIDO2 and
   recovery key), and there is no unattended activation path —
   `systemd-homed-activate.service` has no `ExecStart`, only
   `ExecStop=homectl deactivate-all`. A home is activated **by
   authentication** and locked otherwise; that is the point of homed. So a
   lingering `user@<uid>.service` starts with no accessible `$HOME`. Keep
   anything that must run before login out of the home — see `/srv/users`
   and `/var/lib/containers/users` in `tmpfiles.d/myosi.conf`.

**Post-install root access (fresh image state):**

| Path | State on fresh install | Notes |
|------|------------------------|-------|
| `/etc/shadow` `root` | bootstrap password `changeme` | **Console only** — sshd offers no password method. Destroy it with `passwd -l root` once your user works |
| `/etc/ssh/sshd_config.d/50-myosi.conf` | `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, `AuthenticationMethods publickey` | Root SSH via publickey only. The bootstrap password is **not** remotely usable |
| baked authorized_keys | none in the public image | Root SSH won't work until a key is shipped (overlay, `/etc` drop-in, or credential) |
| interactive user | **none** | You create it on first boot — see [Post-installation](#post-installation) |

So out of the box, only **root at the console** can log in. Everything else
starts from there. Override the bootstrap hash for real fleets by baking
your own over `etc/shadow` via `mkosi.local.conf` `ExtraTrees=`.

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

# NOTE: there is no TPM2 auto-unlock for a homed home. homectl has no
# --tpm2-device/--tpm2-pcrs (they are rejected as unrecognized options);
# TPM2 enrolment applies to the DISK (data-luks, via systemd-cryptenroll),
# not to a homed user's home image. The home unlocks at authentication.
# The strongest unattended-adjacent option homed offers is --fido2-device
# (still requires the token to be present), or --recovery-key for break-glass.

loginctl enable-linger user   # only useful for user units that do NOT need $HOME
PASSWORD=changeme homectl activate user  # use the current user password

# Step 4 (optional, recommended) — re-lock root so password login goes
# back off. Root SSH-as-key still works if you've provisioned a root
# key via any of the sshd sources.
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
# No TPM2 step: homectl has no --tpm2-device (see the note above).
loginctl enable-linger user   # only useful for user units that do NOT need $HOME
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
# NOTE: a homed home is never TPM2-bound, so there is no PCR drift to
# recover from here. PCR drift affects the DISK keyslot (data-luks) — see
# "Re-enroll TPM2 after a firmware / SecureBoot / MOK change" below, which
# uses systemd-cryptenroll and is the real tool for that.

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

- **Steam library** lives at `/var/games/steam`. Create it yourself —
  `sudo mkdir -p /var/games/steam && sudo chown $USER: /var/games/steam`.
  tmpfiles no longer pre-creates `/var/games`: it only made an empty
  root-owned parent, and the per-user subdirectory always had to be made
  and chowned by hand anyway. In Steam: Settings →
  Storage → Add Library Folder → `/var/games/steam`, mark as default
  for new installs. Game configs and save data stay in
  `~/.steam/steam/userdata/` (small).
- **Flatpak** installs go to `/var/lib/flatpak` system-wide by default
  (no `--user`). Shared across users. Per-app data lives in
  `~/.var/app/<app>/` (small).

Why outside /home: game binaries are public — no need for per-user
crypto on top of data-luks. Per-user LUKS homes default to 50 GiB which
Steam would blow past instantly; resize is easy (`homectl update
user --disk-size=200G`) but the out-of-home path is the cleaner
model.

#### 3b. Disk fills itself automatically on first boot

No manual resize step is needed. The initrd boot chain handles disk growth end-to-end:

1. `systemd-repart.service` runs after `sysroot.mount`, reads `/usr/lib/repart.d/*.conf` from the initrd, creates the `data-luks` partition (or grows it to fill the disk on subsequent boots), formats it as LUKS2 + btrfs, and creates `/var`, `/etc`, `/home`, and `/srv` subvolumes.
2. `myosi-data-attach.service` unlocks `/dev/mapper/data` and any present `data-N` pool members and runs `btrfs device scan`. `sysroot-.etc.mount` then mounts `subvol=/etc` at `/sysroot/.etc`, `myosi-etc-prepare.service` creates and labels the two layer directories inside it, and `sysroot-etc.mount` overlays them onto `/sysroot/etc`, before pivot (both mounts are inherited across `switch_root` — they are the data mounts with no unit in the main system); the explicit `var.mount` / `home.mount` / `srv.mount` units mount the siblings post-pivot. btrfs sees the full grown mapper size immediately.
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

Sysexts are signed `.raw` images that merge into `/usr`. Each optional feature is disabled until the host opts in. The helper writes the feature drop-in (`/etc/sysupdate.d/<name>.feature.d/enable.conf`), downloads the release asset for the BOOTED image's `IMAGE_VERSION` (public repo, plain HTTPS — no GitHub auth needed) into the versioned store at `/var/lib/myosi/extensions/`, and refreshes the sysext overlay (`sysext-select` links the matching version into `/var/lib/extensions/`). From then on `myosi update` moves the sysext forward in lockstep with the base image.

Enable the features this host needs:

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

The repo is public: `systemd-sysupdate` fetches straight from the GitHub release (`url-file` sources — the release's `SHA256SUMS` manifest enumerates versions, payload hashes are verified unconditionally, GitHub's asset redirects are followed). No `gh` auth, no local staging step.

Recommended all-in-one update:

```bash
sudo myosi update
sudo reboot
```

One `systemd-sysupdate update` run covers the whole generation atomically: base root + verity + verity-sig + every feature-enabled sysext share one version identifier in `/usr/lib/sysupdate.d/`, and sysupdate never offers a version unless ALL of those transfers have assets for it. The UKI transfer is numbered last (`90-uki.transfer`) so the entry point is written only after everything else landed.

Updates stage only: the new root lands in the inactive A/B slot, the new UKI on the ESP with boot-counting armed (`+3` tries — sd-boot rolls back to the previous UKI/slot after repeated boot failures, `systemd-bless-boot` blesses a healthy boot), and new sysext versions land in the store at `/var/lib/myosi/extensions/` WITHOUT touching the running overlay — `sysext-select` keeps the booted image's versions merged until you reboot into the new slot. Rollback works the same way in reverse: booting the old slot re-selects the old sysexts.

If you intentionally want live extension activation without rebooting:

```bash
sudo myosi update --refresh
```

That runs `systemd-sysext refresh` after staging. Note the refresh re-runs `sysext-select`, which keeps the BOOTED image's sysext versions active — a newer generation activates at reboot. Prefer reboot for root-coupled or kernel-module sysexts such as NVIDIA and ZFS.

Inspect or clean old generations:

```bash
sudo myosi status
sudo myosi vacuum
```

The transfer definitions live in:

```text
/usr/lib/sysupdate.d/            # host root, verity, verity-sig, UKI + sysext features (one @v generation)
```

Pinning: the `url-file` source sees only the LATEST release (`releases/latest/download/`), so `myosi update VERSION` works only when VERSION is the latest. To roll back, boot the previous slot from the sd-boot menu; to install a specific sysext version, use `myosi extension-enable NAME VERSION` (direct per-tag download).

#### 3h. Manual sysext install without `extension-enable`

Use this only for debugging or one-off installs. The normal path is `extension-enable`.

```bash
# The version must match the booted image (kmod sysexts must match the
# running kernel; sysext-select prefers the booted IMAGE_VERSION).
VERSION="$(. /usr/lib/os-release && echo "$IMAGE_VERSION")"
ARCH=x86-64
EXT=containers

curl -fL -o "/tmp/${EXT}_${VERSION}_${ARCH}.raw" \
  "https://github.com/aboglioli/myosi/releases/download/${VERSION}/${EXT}_${VERSION}_${ARCH}.raw"

sudo install -D -m 0644 \
  "/tmp/${EXT}_${VERSION}_${ARCH}.raw" \
  "/var/lib/myosi/extensions/${EXT}_${VERSION}_${ARCH}.raw"

sudo systemctl restart systemd-sysext.service   # runs sysext-select, merges
systemd-sysext list
```

To make sysupdate keep that sysext updated in lockstep later, enable the feature gate too:

```bash
sudo mkdir -p "/etc/sysupdate.d/${EXT}.feature.d"
printf '[Feature]\nEnabled=true\n' | \
  sudo tee "/etc/sysupdate.d/${EXT}.feature.d/enable.conf"

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
The helper stops there — it mounts nothing. Assembling `/etc` is three later units in the same pre-pivot chain: `sysroot-.etc.mount` mounts `subvol=/etc` at `/sysroot/.etc`, `myosi-etc-prepare.service` creates `/.etc/etc` and `/.etc/.work` and stamps `etc_t` on both, and `sysroot-etc.mount` mounts the overlay. All three carry `OnFailure=emergency.target`, so a broken assembly reaches the initrd emergency shell instead of freezing PID 1.

Both mounts it makes are inherited across `switch_root`, which is why there is no `etc.mount` unit in the main system (`systemctl status etc.mount` shows it `Loaded: loaded (/proc/self/mountinfo)`). Both mount units carry `IgnoreOnIsolate=yes`: `initrd-cleanup.service` isolates `initrd-switch-root.target` seconds before the pivot, and without it they are stopped and pid 1 switches root into an empty `/etc`. `/var` is NOT mounted in the initrd — the shipped `var.mount` unit mounts it post-pivot, same lifecycle as `home.mount` and `srv.mount`. These are explicit units, **not** gpt-auto output: `systemd-gpt-auto-generator` is unreliable on verity-protected installs (systemd 259), so myosi owns every post-pivot mount and pins `Options=` itself (a gpt-auto `var.mount` would use btrfs defaults and lose `compress=zstd:3` + `noatime`). On a running host `ls /run/systemd/generator/*.mount` is empty — confirmation that nothing is auto-generated.

There is no sealed-root `/etc/crypttab`, no pre-declared slot list, and no runtime udev/template service for `data-N`. Any `data-N` device that gates `/var` must be present during initrd boot so `myosi-data-attach` can unlock it before the btrfs mount. Post-switch hotplug of unrelated encrypted disks belongs in operator-managed `/etc/crypttab` (persistent on the `/etc` subvol) or explicit units, because those disks do not gate the `/var` or `/etc` subvolumes that the boot path requires.

**Critical systemd behaviour notes that drove this design:**
- `systemd-gpt-auto-generator` does not mount non-root DPS `Type=var` partitions in the initrd; it would only handle `/var` after `switch_root`. myosi does not rely on it at all (it misbehaves on verity-protected installs) — every post-pivot mount is an explicit unit.
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
sudo myosi status

# Signature validation failures
sudo dmesg | grep -iE 'verity|enokey' || true
```

---

## Upgrading an existing host to the sysext store model (one-time)

Hosts deployed before the store + selector model have (a) sysext raws as
REGULAR FILES in `/var/lib/extensions/` — the new `sysext-select` treats
those as operator overrides and keeps them merged forever, pinning stale
versions; (b) feature drop-ins under `/etc/sysupdate.extensions.d/` —
the new transfers live in `sysupdate.d`, so those features silently stop
updating. After booting the first image that ships `sysext-select`, run
once:

```bash
# Move sysext raws into the versioned store (selector takes over):
sudo mkdir -p /var/lib/myosi/extensions
sudo mv /var/lib/extensions/*_*_*.raw /var/lib/myosi/extensions/ 2>/dev/null || true

# Move feature enablement to the merged sysupdate.d component:
for d in /etc/sysupdate.extensions.d/*.feature.d; do
    [ -d "$d" ] || continue
    sudo mv "$d" "/etc/sysupdate.d/$(basename "$d")"
done
sudo rmdir /etc/sysupdate.extensions.d 2>/dev/null || true

# Old gh-fetch cache is no longer used:
sudo rm -rf /var/lib/sysupdate/*

sudo systemctl restart systemd-sysext.service   # sysext-select runs
sudo myosi status                               # verify features + selection
```

Leave any raw you deliberately hand-manage in `/var/lib/extensions/` —
that is exactly the operator-override case the selector respects.

**SELinux policy refresh:** no longer a manual step. The loaded policy at
`/etc/selinux/targeted/policy/` comes from the factory tree through the
overlay, so image-baked policy changes (e.g. the `myosi.cil` module that
lets `systemd-bless-boot` rename UKIs on the ESP — without it every
sysupdate-installed UKI stays unblessed and sd-boot rolls back) and
Fedora `selinux-policy` updates arrive with the image. Confirm nothing
local is shadowing it with `myosi etc-list selinux`. Runtime `semodule`
operations remain unsupported on deployed hosts (the module store is not
shipped); policy changes ship as images.

---

## Migrating an existing host to the /etc overlay

The `/etc` subvolume keeps its name; only its *contents* change meaning. It
used to hold `/etc` directly, and now it holds `etc/` (the upper) and
`.work/`. The migration is **additive**: build those two directories while
the old flat tree is still in place, so the previous A/B slot keeps booting
until you choose to delete it.

Because a pre-overlay host has that subvolume mounted at `/etc`, creating
`/etc/etc` and `/etc/.work` there produces exactly what the new initrd
looks for at `/.etc/etc` and `/.etc/.work`. No rescue environment needed.

**Clear the authselect checksum first — this is the lockout trap.**

```bash
sudo rm -f /var/lib/authselect/checksum
```

`authselect-apply-changes.service` reconciles the PAM stack at boot, but it
compares the profile *source* against that checksum — never the generated
files against `authselect.conf`. A host that already has a checksum is told
"Installed profiles did not change" and keeps whatever `/etc/authselect` it
is handed. Under the overlay that is the factory copy, and if the factory
copy lacks `pam_systemd_home.so` then **no homed user can authenticate, on
tty or over ssh**. `/var` survives the migration, so its stale checksum
survives with it. Removing the checksum makes the service regenerate.

The same rule applies forever after: never `myosi etc-reset authselect`
without clearing the checksum in the same breath.

Then compute what genuinely differs from the image you are about to boot —
not the one you are running:

```bash
sudo myosi update                                    # stage, do not reboot
sudo mount -o ro /dev/disk/by-partlabel/root-<NEW> /mnt/newroot
NEW=/mnt/newroot/usr/share/factory/etc

cd /etc
find . -mindepth 1 \( -type f -o -type l \) -printf '%P\n' | sort | while read -r f; do
    if [ -e "$NEW/$f" ] || [ -L "$NEW/$f" ]; then
        if [ -L "$f" ] || [ -L "$NEW/$f" ]; then
            [ "$(readlink -- "$f")" = "$(readlink -- "$NEW/$f")" ] || echo "differs  $f"
        else
            cmp -s -- "$f" "$NEW/$f" || echo "differs  $f"
        fi
    else
        echo "hostonly $f"
    fi
done
```

Everything absent from that list is byte-identical to the image and must
NOT be copied — that is the whole point. Review what remains and copy only
host identity and real local config into the upper:

```bash
mkdir -p /etc/etc /etc/.work
cd /etc
while read -r f; do cp -a --parents "$f" /etc/etc/; done < /root/etc-keep.txt
chmod 0000 /etc/etc/shadow /etc/etc/shadow- /etc/etc/gshadow /etc/etc/gshadow-
setfattr -n security.selinux -v system_u:object_r:etc_t:s0 /etc/etc /etc/.work
```

Keep: `machine-id`, `hostname`, `hosts` if edited, `localtime`, the ssh host
keys, passwd/shadow/group/gshadow plus their `-` backups, `subuid`/`subgid`,
`ld.so.cache` (it carries sysext library paths and nothing regenerates it
early), every `sysupdate.d/*.feature.d/enable.conf` (lose these and your
sysexts silently disable), the `systemctl enable` symlinks under
`systemd/system/`, and your own drop-ins.

Drop: `selinux/targeted/**` (the frozen policy — dropping it is the fix),
`ld.so.cache`'s siblings under `pki/ca-trust/extracted/`, `dconf/db/`,
`authselect/`, `.pwd.lock`, `.updated`, and anything that differs only
because the image changed underneath a file you never edited.

**Do not run `restorecon` on `/etc` between building the upper and
rebooting.** It relabels by path, and `/etc/etc/shadow` matches no rule —
it would lose `shadow_t` and break PAM after the switch.

Verify before rebooting: the entry count matches your keep list, the ssh
host keys are present, both feature `enable.conf` files are there, and
`/etc/etc` plus `/etc/.work` are `etc_t`.

Afterwards, `/.etc` still holds the old flat tree. Booting the previous
slot works exactly as before while it is there. Deleting it is the point of
no return:

```bash
sudo find /.etc -mindepth 1 -maxdepth 1 ! -name etc ! -name .work -exec rm -rf {} +
```

---

## Operating the `/etc` overlay

`/etc` is the union of the image's defaults (`/usr/share/factory/etc`)
and this host's changes (`/.etc/etc`). The upper is the complete record
of local drift, so these commands read it directly:

```bash
myosi etc-list            # every path this host changed or deleted
myosi etc-diff            # which paths differ from the image's defaults
myosi etc-diff hostname   # content diff of one path
```

`etc-list` marks deletions separately — removing a factory file leaves an
overlayfs whiteout, and it keeps hiding that path even if a later image
reintroduces it.

`/.etc/etc` is a normal directory, so `find /.etc/etc -type f` answers
"what did I change here" without any tooling at all.

### Giving a path back to the image

```bash
myosi etc-reset ssh/sshd_config.d/50-myosi.conf   # stop overriding it
myosi etc-prune                                   # what overrides nothing? (dry run)
myosi etc-prune apply                             # drop all of those
```

`etc-prune` finds two kinds of dead weight: upper files that are now
byte-identical to the image's version (something rewrote the file without
changing it, and it silently stopped tracking the image), and whiteouts
for files the image no longer ships.

Both commands end with **reboot to apply**. The kernel makes no promise
about the view of an overlay whose upper was edited underneath it, and
only the initrd can remount `/etc`, so the change is real on disk
immediately but `/etc` may keep showing the old content until the reboot.

### Recovery

| Situation | Move |
|---|---|
| One file broken | `myosi etc-reset <path>`, reboot |
| `/etc` broken enough that the host won't boot | boot the previous slot from the sd-boot menu; or from the USB installer, `mount /dev/mapper/data -o subvol=/etc /mnt` and fix `/mnt/etc` directly — it is a plain directory |
| Want the image's `/etc` wholesale | from rescue: `mount /dev/mapper/data -o subvol=/etc /mnt && mv /mnt/etc /mnt/etc.broken && mkdir /mnt/etc`, reboot |

Note that `restorecon -RF /etc` is safe but does nothing on a fresh
overlay: the factory tree is already labelled as `/etc` at build time via
the `file_contexts.subs` alias, so a forced relabel rewrites nothing and
copies nothing up. `myosi-sysext-relabel.service` still runs it because
files *created* at runtime do need it — ssh host keys land `etc_t` rather
than `sshd_key_t` — and since those files are already in the upper,
relabelling them causes no copy-up either.

---

## Updates (native sysupdate over GitHub Releases)

The deployed update interface is:

```bash
sudo myosi update
sudo myosi update --refresh
```

By default, updates are staged only. Reboot activates the new root, UKI, and sysexts together. `--refresh` is an explicit live-extension mode: it refreshes the active sysext overlays after staging, but `sysext-select` keeps the booted generation's versions merged, and it does not change the running root or restart affected services.

Under the hood, `myosi update` is a thin wrapper over the native mechanism:

1. `systemd-sysupdate update` reads `/usr/lib/sysupdate.d/` — `url-file` sources pointing at `https://github.com/aboglioli/myosi/releases/latest/download/`.
2. sysupdate downloads the release's `SHA256SUMS` manifest, enumerates versions from the asset filenames (`@v`), and only offers a version complete across the base transfers AND every enabled sysext feature — one atomic generation.
3. Payloads are downloaded (GitHub's redirects followed) and verified against the manifest hashes unconditionally; the artifacts additionally self-authenticate at boot (dm-verity signatures against the kernel `.platform` keyring, SecureBoot-signed UKI). `Verify=false` skips only the optional GPG signature on the manifest itself — flip it on later by shipping `SHA256SUMS.gpg` + `/etc/systemd/import-pubring.pgp`.
4. Root/verity/verity-sig land in the inactive A/B slot, sysext raws in the versioned store, and the UKI last (`90-uki.transfer`) with boot-counting armed (`+3` tries; `systemd-bless-boot` blesses a good boot, sd-boot falls back to the previous entry otherwise).

Automatic updates: the stock `systemd-sysupdate.timer` can drive the same definitions unattended — enable it per host with `systemctl enable --now systemd-sysupdate.timer` (reboot remains manual).

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

### Filesystem maintenance timers

```bash
systemctl list-timers --all
```

Shipped enabled: `fstrim.timer` only (Fedora's weekly default; discards on every mounted FS that supports it).

**Scrub is configured but deliberately NOT enabled.** The `btrfsmaintenance` package is installed, so the native units exist — `btrfs-scrub`, `btrfs-balance`, `btrfs-trim`, `btrfs-defrag`, each with a `.service` and `.timer`, plus `btrfsmaintenance-refresh.path` — and `/etc/sysconfig/btrfsmaintenance` already points them at this layout. Every unit is left inactive: whether a multi-hour read of the whole pool belongs on a schedule depends on the host, so that part is the operator's call.

(`btrfs-progs` ships no systemd units of its own on Fedora. Earlier revisions of this document told you to enable a `btrfs-scrub@<mountpoint>.timer`; that template does not exist, and the command silently did nothing.)

#### What scrub actually does

It reads every allocated block, verifies it against its stored checksum, and where a second copy exists, rewrites the bad copy from the good one. It is not defragmentation, not balance, and it frees nothing.

Note what btrfs already does without it: **checksums are verified on every read**, so corruption in a file you actually use surfaces as an EIO the moment you touch it. Scrub's added value is finding rot in data you have *not* read lately, and exercising the disks so a failing device shows up in `btrfs device stats` before it takes something with it.

What it can repair depends on the profile, and on this layout the two halves differ:

| | profile | scrub can |
|---|---|---|
| metadata | `RAID1` | detect **and repair** from the mirror |
| data | `single` | detect only — there is no second copy |

So a reported data checksum error is a restore-from-backup signal, not something scrub fixes.

#### Running one by hand

Scrub is per **filesystem**, not per subvolume: `/var`, `/etc`, `/home` and `/srv` are all subvolumes of the same `data-luks` btrfs, so one pass over `/var` covers all of them and every `data-N` pool member. The verity-erofs root needs nothing — dm-verity hashes every block it reads.

```bash
sudo btrfs scrub start -B -c 3 -n 4 /var   # -B foreground, idle I/O class
sudo btrfs scrub status /var
sudo btrfs device stats /var               # non-zero counters = a disk going bad
```

`-B` keeps it in the foreground so you see the result; drop it to run detached and poll with `status`.

#### If you want it scheduled

The image enables no timer — that decision is yours. The config is already pointed at the pool, so it is one command:

```bash
sudo systemctl enable --now btrfs-scrub.timer
systemctl list-timers btrfs-scrub.timer
```

Monthly, `Persistent=true` (a missed run fires at the next boot), idle I/O and CPU priority.

`mkosi.extra/etc/sysconfig/btrfsmaintenance` is the Fedora file with four values changed — `BTRFS_{SCRUB,BALANCE,TRIM}_MOUNTPOINTS` from `/` to `/var`, and `BTRFS_BALANCE_PERIOD` from `weekly` to `none`. Upstream aims at `/`, which here is read-only verity-erofs: `btrfs-scrub.sh` skips any non-btrfs path and exits 0, so the packaged default would have given you a green timer that scrubs nothing. `/var` alone suffices — one filesystem, four subvolumes. Balance is `none` because unattended balance on `Data,single` is operator judgment; trim is `none` so it does not collide with `fstrim.timer`.

The period keys are inert on their own. `btrfsmaintenance-refresh.service` reads them and writes `OnCalendar=` into `/etc/systemd/system/<unit>.timer.d/schedule.conf`, enabling or disabling each timer to match; `btrfsmaintenance-refresh.path` triggers it on config changes. Both are disabled by the base preset, so nothing reconciles behind your back — enable the path unit only if you want config edits to re-drive the timers:

```bash
sudo systemctl enable --now btrfsmaintenance-refresh.path
```

To change the cadence, set `BTRFS_SCRUB_PERIOD` to any `systemd.time(7)` calendar expression and run `sudo systemctl start btrfsmaintenance-refresh.service`. The drop-in lands in the `/etc` overlay upper, which is correct — it is a per-host decision.

Fedora ships no `btrfs-scrub@.timer` template; the units are plain, one per task, driven by this config file.

### Manual maintenance — recommended cadence

**Weekly (timer):** `fstrim -av`. Already automated by `fstrim.timer`. Verify:

```bash
sudo journalctl -u fstrim.service --since "1 month ago"
```

**Monthly (timer, once you enable it):** `btrfs scrub`. One pass over `/var` scrubs the whole data-luks pool. Verify:

```bash
sudo btrfs scrub status /var           # the pool: /var /etc /home /srv
sudo btrfs scrub status /home/user     # a separate filesystem — see below
sudo journalctl -u btrfs-scrub.service --since "2 months ago"
```

An activated homed home is its own LUKS volume with its own btrfs inside it, so it is **not** covered by the pool scrub and no timer can reach it — it only exists while that user is logged in. Scrub it by hand from a session:

```bash
sudo btrfs scrub start -B -c 3 -n 4 /home/user
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

# Scrub state. /var /etc /home /srv share one filesystem and report the
# same run; an activated /home/<user> is a separate one.
for m in /var /home/user; do
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
- `/var/lib/myosi/extensions/` — versioned sysext store (re-downloadable, but saves a fetch on restore)
- LUKS recovery passphrase — store outside the machine; TPM2 is convenience, not backup

**Recovery paths:**

| Failure | Recovery |
|---------|----------|
| Bad base update | sd-boot boot counting should roll back after failed boots. Manual path: press Space at sd-boot menu and select the previous UKI/root slot. |
| Bad sysext | Run `sudo myosi extension-disable NAME`, or boot previous base / emergency shell and remove the bad image from `/var/lib/extensions/`, then reboot. |
| Broken local `/etc` file | `myosi etc-reset <path>` then reboot — the overlay drops this host's copy and the image's version shows through again. A whole subtree works the same way. |
| Reset entire `/etc` to verity baseline | `mount /dev/mapper/data -o subvol=/etc,noatime /mnt && mv /mnt/etc /mnt/etc.broken && mkdir /mnt/etc && umount /mnt && reboot`. The old upper is kept next to the new one until you delete it. |
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
| `root` | `changeme` (sha-512 hash in `/etc/shadow`) | **Console only** — sshd has no password method. Destroy with `passwd -l root` after creating your user |
| interactive user | **none shipped** | `myosi-homed-user@.service` is disabled; you create your own with `homectl create` on first boot |

Hashes are baked into `mkosi.extra/etc/shadow` (sha-512 + fixed salt for reproducible builds). `systemd-sysusers` preserves shipped shadow entries on first boot, so the hash survives user creation.

`sysusers.d` has **no password column** in its format (6 fields: `TYPE NAME ID GECOS HOME SHELL`), so the only declarative path for shipping a default password is `/etc/shadow` itself. A 7th column triggers `Trailing garbage.` from `systemd-sysusers` and the entry is dropped — verified the hard way during the password-bootstrap refactor.

**Bootstrap flow on a fresh install:**
1. Log in at the **console** as `root` / `changeme`. (Not over SSH — sshd is publickey-only.)
2. `homectl create <you> --uid=1000 ...` — create the real, properly-named user. See [Post-installation](#post-installation) for the full command and why the name can't be changed later.
3. Verify `<you>` can log in on another TTY, then `passwd -l root` to destroy the bootstrap credential.

The image ships exactly one known credential, it is unusable remotely, and step 3 removes it. Override the baked hash for real fleets via `mkosi.local.conf` `ExtraTrees=`.

**SSH:**
- Key-only (`PasswordAuthentication no`)
- No authorized keys ship in the public image. sshd reads four sources (`sshd_config.d/50-myosi.conf`): `~/.ssh/authorized_keys`, operator-managed `/etc/ssh/authorized_keys.d/<user>`, a baked `/usr/share/myosi/ssh/authorized_keys.d/<user>` (provide via private `mkosi.local.conf` `ExtraTrees=` overlay), and the `ssh.authorized_keys.<user>` systemd credential.
- Modern crypto only (curve25519, chacha20-poly1305, ed25519, no diffie-hellman-group14)
- `MaxAuthTries 3`, `LoginGraceTime 60`, no X11/UserEnv/UserRC

**sudo:** `%wheel ALL=(ALL) ALL`. `user` is in `wheel`. Prompts for password each `timestamp_timeout=15` minutes.

**Rootless podman:** `/etc/subuid` + `/etc/subgid` bake only the static image-owned identities — `root` at `1500000:200000`, `containers` at `2000000:1000000`. The interactive user is **not** baked (the image ships none, and the name is per-host); `myosi-homed-user@<name>` allocates it the first free `1000000`-wide gap at or above `100000` on provisioning.


### Container storage layout

**The image ships no containers configuration at all.** podman runs on its packaged defaults; the only per-host piece is one file in each user's home, provided by `myenv`.

| | graphroot | runroot | comes from |
|---|---|---|---|
| root | `/var/lib/containers/storage` | `/run/containers/storage` | podman defaults |
| rootless `<uid>` | `/var/lib/containers/users/<uid>` | `$XDG_RUNTIME_DIR/containers` | `~/.config/containers/storage.conf` |

```toml
# ~/.config/containers/storage.conf — myenv, linked by `myenv setup-config`
[storage]
graphroot = "/var/lib/containers/users/$UID"
```

Rootless storage is moved out of `$HOME` because homed's idmapped mount maps only the user's own UID — subuid (100000+) writes inside the LUKS home fail `lchown` with `EOVERFLOW` — and because image layers would otherwise grow the encrypted home. `tmpfiles.d` creates `/var/lib/containers/users` `1777` so each user can make its own subdirectory; that line is the only container-related thing the image still ships.

Why per-user rather than a system-wide `rootless_storage_path`, which is the obvious approach:

- **Scope leakage.** With `rootless_storage_path` set and `graphroot` unset, podman 5.8.4 applies the rootless path to *root* as well, expanding `$UID` to `0` — rootful podman silently lands in `users/0` and orphans the real graphroot. Adding `graphroot` fixes that on 5.8.4, but the podman 6 in mybox reportedly breaks rootless outright when a system config sets `graphroot`. Either way the correct file is version-dependent.
- **A user-scope config is not.** Each scope reads an explicit value and nothing is inferred, so the same pair works across podman generations. `$UID` does expand in a user-scope file, so one file serves every host and user.
- **Nothing is lost by living in the home.** Rootless podman cannot run without `$HOME` anyway — it fails with `cannot resolve <home>` — so a locked homed home already rules it out, config file or not.

The cost is real and worth stating: on podman 5.8.4 a user without that file silently stores images in `$HOME/.local/share/containers/storage`, which is exactly what this avoids. On podman 6 it is worse than silent — measured on 6.1.0, a rootless user with no user-scope file inherits the *system* `graphroot` and `runroot`, i.e. `/var/lib/containers/storage` and `/run/containers/storage`, both `0700 root`, and podman fails outright. Since Fedora's vendor `storage.conf` does set `graphroot`, the myenv file stops being an optimisation and becomes what keeps rootless podman working. Worth re-checking when the F45/podman 6 rebase lands, since it implies stock Fedora must drop `graphroot` from that file.

Two podman behaviours that shaped this, both measured:

- **`/usr/share/containers/containers.conf.d/` is not read.** podman's drop-in tiers are `/etc/containers/containers.conf.d/` and `~/.config/containers/containers.conf` — a file under `/usr/share` is silently ignored. `storage.conf` *does* have a `/usr/share` tier; `containers.conf` has a `/usr/share` file but no `/usr/share` drop-in directory. Anything that needs a `containers.conf` setting must go to `/etc` or the user's home.
- **`[storage.options]` is root-only.** The rootless code path discards every graph-driver option, so `mountopt` and `additionalimagestores` never apply to a rootless store. `[storage.options.pull_options]` is the sole exception.

Defaults inherited by dropping our config: `driver = overlay` (autodetected as overlay on btrfs even with the key absent), `mountopt = nodev,metacopy=on` from Fedora's vendor file — which costs `Native Overlay Diff` — `init = false`, and `compression_format = gzip`. The first is harmless; the rest are the price of carrying no configuration.

**`/var/lib/containers` is deliberately *not* NoCOW.** `nodatacow` implies `nodatasum`, so scrub cannot verify a single byte of it, and it disables compression — measured on a host that had `+C` set: 8.7 G of layers at 0% compression, while the rootless store, which never inherited the flag, compresses 41% (432 M → 178 M). btrfs scopes `nodatacow` to frequent-overwrite workloads (databases, VM images); image layers are written once and read many times. No distribution's packaging sets `+C` here — the only upstream NoCOW policy is systemd's on `/var/log/journal`, and its own comment justifies that by journal files carrying internal checksums, which layer files do not. `/var/lib/libvirt` and `/var/lib/incus` keep `+C`: VM disk images are precisely the documented case.

`tmpfiles.d` simply has no entry for the path, which sets policy for new files only — a host built when the `+C` line still existed keeps the inherited flag and must be cleared by hand once:

```bash
sudo chattr -C /var/lib/containers /var/lib/containers/cache
lsattr -d /var/lib/containers /var/lib/containers/cache
```

Clearing it on a directory only affects files created afterwards; btrfs refuses to flip a regular file that already has extents. Existing layers therefore stay uncompressed until they are re-pulled.

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
| `/etc/profile.d/editor.sh` | `EDITOR=VISUAL=nvim` |
| `/etc/profile.d/gpg.sh` | `GPG_TTY` for ssh / tty agent |

### Kernel command line (baked into the signed UKI)

Built from `mkosi.conf` `KernelCommandLine=`. Highlights:
- `rd.systemd.verity=1` + `systemd.verity_root_options=panic-on-corruption,restart-on-corruption`
- `systemd.image_policy=root=signed:var=encrypted:=ignore` + `systemd.image_filter=root=root-*:var=data-*`
- `rd.luks.options=key-file=/usr/share/myosi/keys/data.key,discard` + `rd.luks.timeout=120`
- `lockdown=integrity module.sig_enforce=1 init_on_alloc=1 init_on_free=1 slab_nomerge`
- `mitigations=auto,nosmt page_alloc.shuffle=1 randomize_kstack_offset=on vsyscall=none debugfs=off`
- `selinux=1 enforcing=1`
- `systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all`
- `iommu=pt intel_iommu=on amd_iommu=on` (vendor-agnostic, kernel ignores wrong vendor)
- `module_blacklist=nouveau,nova_core,iTCO_wdt,iTCO_vendor_support,sp5100_tco` — single source of truth for "this module never loads" policy. UKI cmdline is the canonical home; modprobe.d files inside sysexts carry MODULE OPTIONS only.
- `transparent_hugepage=madvise`
- Verbose boot: no `quiet`, `loglevel=4`, `rd.systemd.show_status=true systemd.show_status=true`, `console=tty0` only (qemu adds `console=ttyS0` via mkosi.local.conf)
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
just vm                              # full chain in qemu OVMF (+SSH via `mkosi ssh`)
just vm virt desktop                 # same, with locally-built sysexts injected
just nspawn                          # mkosi-managed nspawn boot (no UKI/verity/LUKS)

# Install (same script, target is whatever block device — USB or internal)
just install /dev/sdX                # boot USB from repo build
just install /dev/nvme0n1            # internal disk, auto-pick image
just install /dev/nvme0n1 /dev/sdb   # clone the booted USB onto NVMe
```

### Deployed host (`myosi` — operate)

The `myosi` wrapper only handles **myosi-specific orchestration**: sysupdate (GitHub releases), sysext feature management, and the install script. Everything else (LUKS keyslots, btrfs subvols, snapshots, portable services, credentials) is run with the upstream tool directly — see the post-install runbook (under Installing to real hardware) for the manual commands.

The wrapper scans `/usr/share/myosi/just/` (base modules `00-update.just`, `10-extensions.just`, `40-install.just`) and any sysext-provided modules (e.g. `50-virt.just`) at every invocation, emitting a transient justfile in `/run/myosi/`. Sysexts can add their own operator commands without the base image knowing about them. Run `myosi --list` to see what's currently available.

```bash
sudo myosi extension-enable   NAME [VERSION]   # enable a sysext feature
sudo myosi extension-disable  NAME             # disable a sysext feature
sudo myosi extension-list                      # installed + active sysext
sudo myosi update                              # stage base + sysexts + machines (systemd-sysupdate)
sudo myosi update --refresh                    # …plus live sysext refresh
sudo myosi status                              # update + sysext state
sudo myosi vacuum                              # remove old generations
sudo myosi install             /dev/sdX [SRC]  # write a release to disk
```

Day-2 ops use upstream tools directly:

```bash
# LUKS keyslot management — see the post-install runbook
sudo cryptsetup luksAddKey --key-file /usr/share/myosi/keys/data.key \
    /dev/disk/by-partlabel/data-luks                       # add passphrase
sudo systemd-cryptenroll --wipe-slot=tpm2 \
    /dev/disk/by-partlabel/data-luks                       # remove TPM2

# btrfs pool — see Filesystem maintenance
sudo btrfs filesystem show /var
sudo btrfs balance start -dconvert=single -mconvert=raid1 -sconvert=raid1 /var

# Snapshots — see Snapshots + rollback
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
# Stage latest GitHub release through local sysupdate cache
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
- `initrd-cleanup.service` runs `systemctl --no-block isolate initrd-switch-root.target` seconds before the pivot. Without `IgnoreOnIsolate=yes`, the mount is stopped and the kernel pivots into an empty `/etc`. Both `sysroot-.etc.mount` and `sysroot-etc.mount` set it, and ordering is maintained by the explicit `After=` chain from `myosi-data-attach.service`.

### `/dev/mapper/data` or `/var` is only ~240 MiB after install
- The data partition should grow in the initrd before pivot. If it stays tiny, inspect `journalctl -b -u systemd-repart.service -u myosi-data-attach.service` from the failed boot or emergency shell.

### `mokutil --import` rejects `/usr/share/myosi/keys/{boot,image}.crt` with `not a valid x509 certificate in DER format`
- mokutil only accepts DER. Recent builds ship both `.crt` (PEM) and `.der` (DER) — use `sudo mokutil --import /usr/share/myosi/keys/{boot,image}.der`. On older builds: `sudo openssl x509 -in /usr/share/myosi/keys/boot.crt -outform DER -out /tmp/boot.der` (the base image now ships `openssl`), same for `image`.

### `/usr/share/myosi/keys/` is empty
- `BuildSources=keys` without an explicit destination flattens `./keys/` into `$SRCDIR/` instead of `$SRCDIR/keys/`, so `mkosi.postinst`'s cert-copy step silently no-ops. Fixed by `BuildSources=keys:keys`. Rebuild + reflash.

### Sysexts fail to merge with a verity signature error
- The kernel has no trusted `image.der`. Enroll `/efi/keys/image.der` into firmware db, or MOK-enroll `/usr/share/myosi/keys/image.der` with `mokutil --import`. Reboot, then verify with `sudo keyctl list %:.platform` and `sudo keyctl list %:.machine`. Unsigned sysexts are possible by changing `mkosi.shared/sysext.conf` from `Verity=signed` to `Verity=yes`, but then you keep Merkle-tree integrity without the PKCS#7 authenticity check.

### Login as `root` rejects `changeme` (nspawn)
- nspawn was launched with `--read-only` instead of `--volatile=overlay`. Without overlay, `/etc/shadow` is RO and systemd-sysusers can't write the hash. Re-launch with `--volatile=overlay`.

### There is no user to log in as after install
- Expected — the image ships none. Log in at the **console** as `root` / `changeme` and create yours with `homectl create`; see [Post-installation](#post-installation). SSH won't work for this: sshd is publickey-only, so the bootstrap password is console-only by design.

### `myosi extension-enable` doesn't add me to `libvirt` / `incus-admin`
- Group binding runs from `myosi-homed-user@<you>.service`, which is not enabled by default. `systemctl enable --now myosi-homed-user@<you>.service`, then log out and back in (group changes apply at next login). Verify the drop-ins exist under `/usr/share/myosi/user-groups.d/` and check `journalctl -u myosi-homed-user@<you>.service`.

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
  - **`ZFS_BUILD_OPTIONAL=1`**, which makes `dnf install`, tarball fetch, configure, and rpmbuild failures non-fatal (empty sysext stub, exit 0). NOT set in CI releases on purpose: base + sysext transfers share one sysupdate generation, so a release missing the zfs asset would be silently invisible to every host with the zfs feature enabled — a loud CI failure is the better trade. Use it for local builds while waiting on upstream.

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
sshd, sudo, podman, NetworkManager, and firewalld read their active config from `/etc/`. myosi therefore keeps security-sensitive defaults in `mkosi.extra/etc/` as the verity-protected baseline, `mkosi.finalize` snapshots that baseline to `/usr/share/factory/etc`, and that tree is the overlay's lower — so those defaults stay live and keep updating with the image unless this host has explicitly overridden the file. Reusable signed configuration ships as sysexts under `/usr` instead of stacking a confext layer.

**Why `vm.swappiness=180`?**
zram is always-on. Swap pages go to zstd-compressed RAM, not disk. Aggressive swappiness is correct in that regime. Without zram, 180 would thrash to disk; with it, you get effective memory compression.

**Why one base image instead of per-host images like myos?**
A slim signed base + per-host opt-in sysexts means every host runs the same updateable artifact. Per-host images multiply the update + signing surface. Host identity lives in the persistent `/etc` btrfs subvol on `data-luks`; reusable signed configuration ships as additional sysexts under `/usr`.

**Why pasta instead of slirp4netns for rootless podman?**
slirp4netns works but is slow, IPv6-limited, and the legacy default. pasta (passt) is faster (kernel-based packet shuttling), has full IPv6 support, and is already podman's default from 5.x on — myosi configures nothing and gets it. myos pins slirp4netns; podman 6 removes it entirely.

**Why is `/etc` writable when the rest of the root is RO?**
systemd-sysusers, systemd-machine-id-commit, sshd-keygen, NetworkManager, and password changes need writable `/etc` at runtime. myosi gets that from an overlay whose upper is a btrfs subvolume on `data-luks`: writes land in `/.etc/etc`, everything else is read straight from the verity-baked factory tree. Host-owned config should still prefer signed sysexts; local `/etc` edits are for machine-local state and emergency overrides.

**Why is `/etc` an overlay instead of a plain btrfs subvolume?**
A plain subvolume has to be seeded once and is then frozen: files added to `/usr/share/factory/etc` in later images never arrive, changed defaults never apply, and reconciliation depends on an operator remembering to diff after every upgrade. That is not a hypothetical — on this host `/etc/myosi/users/` is absent and `selinux/targeted/contexts/` is stale, because both changed in the factory tree after first boot and nothing carries such changes across. The overlay inverts the default: untouched paths track the image, touched paths stay yours, and the upper is an exact record of the difference.

An earlier overlay attempt was retired, but its problems were all properties of putting the upper at `/var/etc` — `/var` cannot mount before `/etc`, PID 1 pinned `var.mount` open at shutdown, and the upper's SELinux context was cached before the first-boot relabel. Keeping the layers inside the `/etc` subvolume, mounted at `/.etc` in the initrd, removes all three. The remaining cost is real and specific: copy-up is per-file and permanent until reset, so a file touched for any reason stops tracking the image until `myosi etc-prune` or `myosi etc-reset` puts it back — `myosi etc-list` is what makes that visible rather than silent.

**Why does `myosi-data-attach` use `udevadm info` instead of `blkid` for partition metadata?**
`blkid -s PART_ENTRY_TYPE` silently exits 2 on dm-verity-backed partitions — it tries to probe the filesystem layer and aborts before reporting partition-table metadata. `udevadm info --query=property` reads `ID_PART_ENTRY_TYPE`/`ID_PART_ENTRY_NAME` from udev's per-device DB, which is populated at coldplug time from the parent disk's partition table. Since `udevadm settle` runs before partition discovery, the values are always available. The helper also parses the property dump with pure bash (`IFS='=' read`) because mkosi-initrd ships no awk/grep/cut.

**Why does `sysroot-etc.mount` have `IgnoreOnIsolate=yes`?**
`initrd-cleanup.service` runs `systemctl --no-block isolate initrd-switch-root.target` seconds before the pivot. This isolate stops every unit not pulled in by the target. Without `IgnoreOnIsolate=yes`, the mount would be stopped seconds before pivot — the kernel would switch root into an empty `/etc`, SELinux policy load would fail, and pid 1 would freeze. `sysroot-.etc.mount` needs it for the same reason.

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
| **v1.2: writable /etc in real initrd** | ✅ done — cpio sub-image `mkosi.images/initrd/` (Include=mkosi-initrd, bash+cryptsetup+btrfs-progs+util-linux+attr); `myosi-data-attach.service` finds root disk, selects its `Type=var` partition, unlocks as `/dev/mapper/data` (key-file probe → TPM2/passphrase fallback), unlocks `data-N` pool members across ANY disk, scans btrfs; `sysroot-.etc.mount` + `myosi-etc-prepare.service` + `sysroot-etc.mount` then mount the `/etc` subvolume at `/sysroot/.etc` and overlay its layers with the factory tree onto `/sysroot/etc`. `/var` is mounted post-pivot by gpt-auto-generator (Type=var + DefaultSubvolume=/var), same lifecycle as home.mount and srv.mount. Uses `udevadm info` for partition metadata (blkid exits 2 on dm-verity partitions). No `/etc/fstab` or `/etc/crypttab` in the sealed root — all unlock/mount declarative. **The `/etc` overlay was retired once (upper at `/var/etc`) in favour of a plain seeded subvolume, then reinstated with its layers inside the `/etc` subvolume mounted at `/.etc` — see "The /etc overlay".**
| **v1.3: signed kernel modules + module blacklist on UKI cmdline** | ✅ done — every `nvidia*.ko` / `zfs.ko` / `spl.ko` signed with `boot.key`; `module_blacklist=` baked into UKI cmdline as the single canonical blacklist source. |
| **v1.4: NVIDIA sysexts working** | ✅ done — both `nvidia` (595.x open, Turing+) and `nvidia-580xx` (580.x proprietary, Pascal/Maxwell/Volta) build cleanly against kernel 7.0.10. Root cause was missing `/dev` + `/proc` in mkosi sandbox chroot, fixed via `mkosi.shared/kmod-build.sh`. |
| **v1.5: OpenZFS sysext via upstream tarball** | ✅ done — `zfs-build.sh` pulls `zfs-${ZFS_VERSION}.tar.gz`, generates SRPMs with `make srpm-utils srpm-kmod`, rebuilds via `kmod_exec rpmbuild`, signs `zfs.ko` + `spl.ko`. No dependency on zfsonlinux.org/fedora packaging that lags new Fedora releases. |
| **v1.6: fleet-keys sysext baked into base** | ✅ done (since retired — the public repo ships no keys; see SSH hardening section) — `/usr/lib/extensions/fleet-keys_VER_ARCH.raw` ships in the verity-protected root for first-boot SSH; sysupdate rotations land in `/var/lib/extensions/` and win precedence. Originally shipped as a confext; reworked as a sysext that drops `authorized_keys` under `/usr/share/myosi/ssh/authorized_keys.d/` and is read by sshd via an `AuthorizedKeysFile` token. |
| **v1.7: prerelease versioning + bare tags** | ✅ done — `YYYY.MM.DD.NN` for stable, `-rc.N` / `-beta.N` / `-alpha.N` for prereleases. No `v` prefix anywhere — filenames + tags identical. CI workflow `prerelease` input validates `(alpha|beta|rc)\.N`. |
| **v1.8: locked root + bootstrap via user sudo** | ⬅️ superseded — this shipped `root:!locked` plus a default `user`/`changeme`. Reversed once the repo went public: a generic `user` is unrenameable (no `homectl rename`), so the image now ships **no** interactive user and a **console-only** root bootstrap instead. See [Post-installation](#post-installation). |
| **v1.9: incremental build mode** | ✅ done — `just build` runs `mkosi -fi` for fast local iteration; `just build full` runs `mkosi -ff` for clean releases; CI workflow pinned to full. |
| **v2: real-hardware install** | ⬜ pending — dd → USB → install → boot a sacrificial target |
| **v3: sysupdate end-to-end** | ✅ done — `systemd-sysupdate` fetches straight from the public GitHub release (`url-file` + `SHA256SUMS`); base + enabled sysexts update as one atomic generation, machines as a separate component. |
| **v4: TPM2 enrollment + dual SecureBoot validation** | ⬜ pending |
| **v5: fleet rollout** | ⬜ pending — replace `myos` on remaining hosts |
| **v6: public artifact store decision** | ✅ resolved — the repo is public; GitHub Releases IS the artifact store, consumed natively by sysupdate (`releases/latest/download/` + manifest). The `gh`-backed cache fetcher is retired. |

---

## See also

- **Design notes — current model** section below — image shape, first-boot credentials, portable services
- **Signing keys** appendix below — key generation + rotation runbook
- **Multi-disk storage runbook** appendix below — manual install + multi-disk patterns
- `myos` — sibling bootc project (private myenv repo; being superseded by myosi)

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
- Login: `root` / `changeme` (the only shipped credential; no interactive user is created — see "Default credentials" below).

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
mkosi ssh -- mount | grep -E 'erofs|btrfs'
# Should show:
#   /dev/mapper/root on / type erofs (ro,...)
#   overlay on /etc type overlay (rw,...,upperdir=/.etc/etc)
#   /dev/mapper/data on /var type btrfs (rw,...,subvol=/var)

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
cp build/desktop_${VERSION}_${ARCH}.raw /tmp/myosi-extensions/
cp build/virt_${VERSION}_${ARCH}.raw    /tmp/myosi-extensions/

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

# 3. /etc persistent btrfs subvolume
findmnt /etc
# Should show: /etc  overlay  overlay  rw,...,upperdir=/.etc/etc

# 4. /usr read-only
findmnt /usr
touch /usr/test 2>&1
# Should fail: Read-only file system

# 5. /var + /home on encrypted btrfs
findmnt /var | grep btrfs
findmnt /home | grep btrfs
btrfs subvolume list /var
# Should list the top-level subvolumes: var, etc, home, srv
# (/var/tmp, /var/log, /var/lib/containers are plain dirs inside /var)

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
sudo systemd-dissect build/virt_*.raw
# Shows: type=sysext, image_id=virt, extension-release metadata

sudo systemd-dissect --list build/virt_*.raw | head -30
# Lists all files in the extension
```

#### In qemu

Inject with `--runtime-tree` at boot. No rebuild, works with signed images, full signature validation.

#### In nspawn

Bind-mount extensions into a running nspawn instance:

```bash
# Stage extensions
mkdir -p /tmp/myosi-extensions
cp build/virt_*.raw /tmp/myosi-extensions/

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
cp build/virt_*.raw /tmp/myosi-extensions/
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

# Design notes — current model

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

(data-luks unlock does NOT use a credential: the initrd
`myosi-data-attach.service` probes the baked key file at
`/usr/share/myosi/keys/data.key`, then falls through to TPM2/passphrase
via `systemd-cryptsetup`.)

Operators manage credentials with `systemd-creds` directly:

```bash
# Encrypt + install (seal to TPM2 if available, host-key otherwise):
echo 'myhost-01' | sudo systemd-creds encrypt --name=firstboot.hostname \
    - /etc/credstore.encrypted/firstboot.hostname

# Listing and removal:
sudo systemd-creds list
sudo rm /etc/credstore.encrypted/firstboot.hostname
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

Operators drive it with `portablectl` directly:

```bash
sudo install -m 0644 /tmp/myservice.raw /var/lib/portables/
sudo portablectl inspect myservice.raw           # signatures, units, content
sudo portablectl attach --enable myservice       # mount + enable units
sudo portablectl list                            # state
sudo portablectl detach myservice                # stop + unmount
```

**confext is dormant by default.** myosi's `/etc` is a persistent btrfs
subvolume the operator owns after first boot. A confext layer would
stack an image-shipped overlay on top of it, and the reconciliation
rules (which side wins on conflict, what survives a confext detach, how
sysupdate phases interact with an overlay swap) would need a design
pass first. `systemd-confext.service` is therefore not preset-enabled —
but also not masked; operators who accept those open questions can
`systemctl enable --now systemd-confext.service`.

Extensions are **sysexts** (`/usr` files), **portable services** (own
`/etc` namespace), or **operator edits to `/etc`** (persistent per-host
config). Nothing else.

---


---

# Multi-disk storage runbook (appendix)

Detailed patterns for joining multiple encrypted disks into either
the existing `/var` btrfs pool or a separate pool. The basic single-
disk install path is covered under **Installing to real hardware**
above; this section adds the multi-disk operator workflows.

## 2. Multi-disk storage layouts

myosi's `/var` is a btrfs filesystem inside one LUKS container. It can be extended into a pool spanning multiple encrypted devices. Or you can create a separate pool mounted elsewhere (e.g. `/mnt/data`) for bulk storage.

No wrapper scripts ship for this — the patterns below use `cryptsetup`,
`systemd-cryptenroll`, and `btrfs` directly. The canonical single-disk
commands live in section 3i (Encrypted btrfs data pool); this appendix
composes them into multi-disk layouts.

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
# Boot from primary install (see Installing to real hardware)
# Then on the running system:

# Encrypt the second NVMe with a data-N label (the pattern the initrd
# myosi-data-attach scanner adopts as a pool member) and enroll TPM2
# for unattended unlock — full rationale in section 3i.
sudo wipefs -a /dev/nvme1n1
sudo cryptsetup luksFormat --type luks2 --label data-1 --force-password /dev/nvme1n1
sudo cryptsetup luksOpen /dev/nvme1n1 data-1
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 /dev/nvme1n1

# Add to the /var btrfs pool
sudo btrfs device add /dev/mapper/data-1 /var

# Verify — should show TWO devices in the pool
sudo btrfs filesystem show /var

# Use 'single' profile to keep full usable capacity
sudo btrfs balance start -dconvert=single -mconvert=raid1 -sconvert=raid1 /var
```

Boot persistence: no crypttab needed — the initrd `myosi-data-attach` discovers and unlocks every `data-N`-labeled LUKS container on any disk before `/var` mounts.

### 2.3 Pattern B: separate mirrored data pool for HDDs

Hosts with extra SATA HDDs for bulk storage (e.g. `/dev/sda` and `/dev/sdb`) intended for redundant bulk storage. Mounted at `/mnt/data`:

```bash
# Encrypt each device with a pool-* label (NOT data-N — these disks do
# not gate /var, so they use operator-managed /etc/crypttab instead of
# the initrd scanner) and register it for boot-time unlock:
for D in /dev/sda /dev/sdb; do
    L="pool-$(basename "$D")"
    sudo wipefs -a "$D"
    sudo cryptsetup luksFormat --type luks2 --label "$L" --force-password "$D"
    sudo cryptsetup luksOpen "$D" "$L"
    echo "$L  UUID=$(sudo cryptsetup luksUUID "$D")  none  discard" | \
        sudo tee -a /etc/crypttab
done

# Optional TPM2 enrollment for unattended unlock on each disk
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 /dev/sda
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 /dev/sdb

# Format btrfs raid1 across the mappers, mount via fstab
sudo mkfs.btrfs -L pool -d raid1 -m raid1 /dev/mapper/pool-*
sudo mkdir -p /mnt/data
UUID=$(sudo blkid -s UUID -o value /dev/mapper/pool-sda)
echo "UUID=$UUID  /mnt/data  btrfs  defaults,noatime,compress=zstd:3  0 0" | \
    sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount /mnt/data

# Verify
sudo btrfs filesystem show /mnt/data
```

Per-disk LUKS passphrases can be the same string (easier to remember) or distinct (slightly better blast-radius).

### 2.4 Pattern C: high-performance stripe (any host with 2 NVMes)

For a pure performance setup where you accept the risk:

```bash
# Same encrypt + crypttab + fstab flow as Pattern B, then:
sudo mkfs.btrfs -L fast -d raid0 -m raid1 /dev/mapper/pool-nvme1n1 /dev/mapper/pool-nvme2n1
```

`raid0` doubles read/write throughput at the cost of any single-disk failure destroying the whole pool. Use only for caches, build artifacts, swap-like workloads.

### 2.5 Adding a disk to a pool later

You can always add more disks to either `/var` or `/mnt/data` later:

```bash
# Existing pool (e.g. /var), add a third disk: encrypt with the next
# data-N label (Pattern A flow), then:
sudo btrfs device add /dev/mapper/data-2 /var
sudo btrfs balance start -dconvert=raid1 -mconvert=raid1 -sconvert=raid1 /var   # raise redundancy
# or keep maximum capacity:
sudo btrfs balance start -dconvert=single -mconvert=raid1 -sconvert=raid1 /var
```

Capacity recomputes automatically. `btrfs balance` rebalances live without unmounting.

### 2.6 Removing a disk from a pool

(Manual; no `just` recipe for this — risky enough to justify being explicit.)

```bash
# Move all data off the device
sudo btrfs device delete /dev/mapper/<label> /var

# After completion, close LUKS. For /var pool members (data-N) also
# wipe the header — the initrd scanner adopts any present data-N label
# as a mandatory boot-time pool member. For separate pools, remove the
# /etc/crypttab line instead.
sudo cryptsetup luksClose <label>
sudo wipefs -a /dev/<device>                      # data-N pool member
sudo sed -i "/^<label>/d" /etc/crypttab           # separate-pool device
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
| `/etc` drift causing weird state | `myosi etc-list` shows exactly what this host changed; `myosi etc-reset <path>` or `myosi etc-prune apply` hands paths back to the image. |
| SecureBoot toggle invalidates TPM | TPM unlock fails → passphrase prompt. Re-enroll TPM2: `sudo systemd-cryptenroll --wipe-slot=tpm2 <luks> && sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+14 <luks>`. |

## 4. Verifying a clean install

After all setup steps, sanity checks:

```bash
# Sysext merged
sudo myosi extension-list

# Verity root active
findmnt /
#   Should show /dev/mapper/root or similar with the verity device shown.

# All LUKS volumes unlocked
sudo dmsetup ls --target crypt

# Pool layout
sudo btrfs filesystem show /var

# Boot-counter blessed (no rollback pending)
sudo systemctl status systemd-bless-boot.service

# Boot chain (if SecureBoot enabled)
mokutil --sb-state
sudo bootctl status

# Latest version is what you expect
cat /usr/share/myosi/version
```

---

# Signing keys (appendix)


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
