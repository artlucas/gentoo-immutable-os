# 01 — System Architecture

## Immutability model

The OS is a **read-only EROFS image** occupying one of two root slots. Nothing on the root
filesystem is ever modified in place — not by the user, not by updates, not by the OS itself.
State lives in exactly two places:

| Path | Backing | Lifetime |
|---|---|---|
| `/` (incl. `/usr`, `/opt`, `/boot` stub) | EROFS image in active root slot | Replaced wholesale by updates |
| `/etc` | overlayfs: lower = image's `/etc`, upper = `/var/overlay/etc/upper` | Local edits persist across updates |
| `/var` | ext4 partition (`PARTLABEL=var`) | Persists across updates, grows to fill disk |
| `/home` | symlink → `/var/home` | Persists (Silverblue-style) |
| `/root` | symlink → `/var/roothome` | Persists |
| `/tmp` | tmpfs | Volatile |
| `/efi` | ESP (vfat), automount, otherwise unmounted | Written only by updater/`bootctl` |

There is no Portage, no VDB, no compiler on the system (see [06-pruning.md](06-pruning.md)),
so "installing software natively" is not merely discouraged — it is impossible. Applications
come from Flatpak into `/var/lib/flatpak`.

EROFS is chosen over squashfs: kernel-native read-only filesystem designed for exactly this
use (Android system partitions), better random-read performance, lz4hc/zstd compression,
first-class in `gentoo-kernel-bin`.

## Disk layout

GPT, UEFI-only. Partition names (GPT partlabels) are the API — everything (initrd, sysupdate,
repart) discovers partitions by label/type, never by `/dev/sdXN`.

```
GPT (protective MBR only; no BIOS boot support)
├── p1  ESP        vfat   1 GiB      PARTLABEL=esp     type=EFI System
│        └── systemd-boot + versioned UKIs (current + previous)
├── p2  root slot  erofs  6 GiB      PARTLABEL=root_<version-A>   type=root(x86-64)
├── p3  root slot  (raw)  6 GiB      PARTLABEL=_empty             type=root(x86-64)
└── p4  var        ext4   4 GiB+     PARTLABEL=var                type=var
                          (grows to fill disk at first boot)
```

Sizes are `config/build.conf` variables (`ESP_SIZE`, `ROOT_SLOT_SIZE`, `VAR_SIZE_INITIAL`).
6 GiB slots leave ~2× headroom over the ~3 GiB compressed root image (budget in
[06-pruning.md](06-pruning.md)). The factory image ships slot B empty (zeros — compresses to
nothing in the distributed `.img.zst`).

### Version-labeled slots (the A/B selection mechanism)

Slots are **not** named "A" and "B" anywhere the OS can see. Instead:

- Each release's root partition is labeled with its version: `root_0.1.0`.
- Each release's UKI embeds the kernel cmdline `root=PARTLABEL=root_0.1.0 rootfstype=erofs ro`.
- The updater writes the new image to whichever slot is *inactive* and relabels that
  partition to the new version (`systemd-sysupdate` does this natively).

So a UKI always finds its own rootfs regardless of which physical slot holds it. No per-slot
UKI variants, no bootloader-side slot logic, no cmdline editing. The unused slot is labeled
`_empty` (factory) or holds the previous version (after ≥2 updates, the oldest is overwritten).

## Boot flow

```
UEFI firmware
  └─ systemd-boot (ESP:/EFI/BOOT/BOOTX64.EFI + /EFI/systemd/)
       picks highest-version UKI in ESP:/EFI/Linux/, honoring boot-counting suffixes
       └─ UKI  immos_<version>[+tries].efi   (kernel + initrd + cmdline + os-release, one PE binary)
            └─ initrd (dracut, systemd-based, hostonly=no)
                 1. systemd-repart grows `var` partition to end of disk (first boot only)
                 2. mount /sysroot            ← root=PARTLABEL=root_<version> (erofs, ro)
                 3. mount /sysroot/var        ← fstab x-initrd.mount entry (PARTLABEL=var)
                 4. etc-overlay unit          ← custom dracut module (see below)
                 5. switch-root
                      └─ systemd (full)
                           ... graphical.target → Plasma Login Manager → Plasma (Wayland)
                           boot-complete.target → systemd-bless-boot marks UKI good
```

### UKI construction

Built entirely in the builder (never on the target — the target has no dracut/ukify):

1. `dracut --sysroot <target> --no-hostonly` produces a generic initrd containing:
   systemd, the etc-overlay module, systemd-repart + our repart.d, erofs/ext4/vfat drivers,
   storage drivers (nvme, ahci, virtio, usb-storage, sd/mmc) and keyboard.
   **No graphics.** dracut's `drm` module is explicitly omitted, and stage 40 asserts that no
   `drivers/gpu` module and no GPU firmware survives into the initrd. This is recent and it is
   the largest single lever anyone has found on the UKI: as long as a splash ran in the initrd,
   the initrd also carried the DRM module tree and — because dracut follows `MODULE_FIRMWARE` —
   everything those drivers declare, which is how amdgpu's 84 MiB and later NVIDIA's 98 MiB of
   GSP firmware ended up on the ESP. The splash now runs *after* switch-root, out of the root
   filesystem, where the GPU driver is already present at no extra cost. See
   [plan/14](14-boot-splash-kms.md).
2. `ukify build --linux=<vmlinuz> --initrd=<initrd> --cmdline="root=PARTLABEL=root_${VERSION} rootfstype=erofs ro nvidia-drm.modeset=1 quiet" --os-release=@<target>/etc/os-release --output=${DISTRO_ID}_${VERSION}.efi`

Cmdline notes: `nvidia-drm.modeset=1` is required for NVIDIA Wayland; harmless without the GPU.
Test builds append `console=ttyS0` (see [07-testing.md](07-testing.md)).
The splash adds `loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0`, plus
`${DISTRO_ID}.splash=0` when `SPLASH_BACKEND` is `stub` or `none`. `quiet` is load-bearing rather
than cosmetic here: with `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y` and no DRM driver in
the initrd, no console output means nothing takes the framebuffer — which is what lets the
`systemd-stub` splash bitmap stay on screen for the whole initrd. See
[plan/14](14-boot-splash-kms.md).
`rd.shell=0 rd.emergency=reboot` are added unless `DEBUG_INITRD=1`, and they are what makes the
rollback below *automatic* rather than merely available — see the note under it.

### Automatic Boot Assessment (rollback)

systemd-boot's built-in boot counting:

- **Factory image:** UKI installed *without* a tries counter (`immos_0.1.0.efi`) — it is the
  known-good baseline; there is nothing to roll back to.
- **Updates:** new UKI lands as `immos_0.2.0+3.efi` (3 tries). systemd-boot decrements the
  counter in the filename each attempt (`+2-1`, `+1-2`, …).
- On a successful boot, `systemd-bless-boot.service` (pulled in by `boot-complete.target`)
  renames it to `immos_0.2.0.efi` — permanent.
- If tries hit `+0-3`, systemd-boot skips the entry and boots the next-highest version — the
  previous UKI, whose rootfs still sits in the other slot. **Automatic rollback, no server, no
  agent.**

The counter is decremented when systemd-boot *starts* an entry, not when the boot finishes, so a
failure that hangs still burns a try — but only one per power cycle, and only if a human is there
to press the button. That was the gap `rd.shell=0 rd.emergency=reboot` closes: an initrd that
cannot mount the root slot used to sit at a dracut emergency prompt indefinitely, so falling back
to the previous UKI took three manual power cycles. It now spends the three tries by itself, in
seconds ([plan/11](11-kernel-boot-audit.md) finding 8). `DEBUG_INITRD=1` in `build.conf` restores
the shell for development images.

What counts as a "successful boot" is defined by what `boot-complete.target` requires. We wire
in `systemd-boot-check-no-failures.service` plus a tiny `immos-boot-ok.service` that asserts
`graphical.target` was reached — so a boot that comes up without a display manager is a failed
boot and gets rolled back. Manual rollback: `bootctl set-default immos_<old>.efi` (or once,
`bootctl set-oneshot`).

## /etc overlay

- Lower: `/etc` from the ro image (pristine vendor config, updated with every release).
- Upper/work: `/var/overlay/etc/{upper,work}`.
- Mounted **in the initrd** by a ~40-line custom dracut module (`90etc-overlay`): a
  systemd unit ordered `After=sysroot-var.mount Before=initrd-switch-root.service` that
  `mkdir -p`s the upper/work dirs and mounts
  `overlay /sysroot/etc -o lowerdir=/sysroot/etc,upperdir=/sysroot/var/overlay/etc/upper,workdir=/sysroot/var/overlay/etc/work`.

Why a custom module and not an fstab `x-initrd.mount` entry: overlay `upperdir=`/`workdir=`
options are absolute paths that systemd's fstab generator would *not* rewrite to `/sysroot/...`
in the initrd context — the entry would point at the initrd's own `/var` and fail. Regular
partition mounts like `/var` don't have this problem, which is why `/var` *does* use fstab.

Semantics (documented tradeoff): overlay upper wins file-wise. A file the user modified stops
receiving vendor updates until the user deletes the upper copy (`immos-update etc-diff` in
the CLI wrapper lists divergent files). No 3-way merge à la OSTree — accepted for v1.

`/etc/machine-id`: empty in the image lower; systemd generates one at first boot and the write
lands in the upper — stable thereafter.

## /var lifecycle

- Shipped 4 GiB, populated at build with: preinstalled Flatpaks (`/var/lib/flatpak`), empty
  `home/`, `overlay/etc/{upper,work}`, factory journal dir.
- First boot: `systemd-repart` (in initrd, `repart.d/50-var.conf` with
  `SizeMaxBytes=` unset + `Weight=`) extends the partition to the end of the physical disk —
  libfdisk relocates the backup GPT header automatically, so a 16 GiB image dd'd onto a 1 TB
  disk claims the full disk. `x-systemd.growfs` on the `/var` fstab entry grows the ext4 to
  match.
- Updates never touch `/var`. A "factory reset" is: wipe `var` + relabel (roadmap: recovery
  UKI that does this).
- swap: zram only (`sys-apps/zram-generator`), no swap partition, no hibernation — **in the
  factory image, which is unchanged.** *Installed* systems get a swap partition and
  hibernation as of 2026-08-28 ([plan/16](16-installer.md) §6): the installer knows the disk
  and the RAM, so the sizing objection goes away, and a discoverable GPT swap type means no
  `resume=` is needed in the UKI cmdline — which is what made this impossible before, since
  that cmdline is baked at build time and identical on every machine.

## First boot & default user

v1 images are "live-style": a `live` user (uid 1000, wheel, configurable name/password in
`build.conf`) is baked into the image `/etc/passwd`/`shadow` at build time, with Plasma Login
Manager autologin into the Plasma Wayland session (`/etc/plasmalogin.conf.d/10-autologin.conf`). Rationale: zero-interaction boot for both VM
evaluation and USB live use. The installer ([plan/16](16-installer.md) §5.4) replaces this with real
user creation. It cannot *delete* the `live` user — that user lives in the read-only EROFS the
installed system also boots — so it shadows `passwd`/`shadow`/`group` from the `/etc` overlay
upper, and adds a `20-no-autologin.conf` drop-in that sorts after the baked-in one. User-created accounts at runtime land in the `/etc` overlay
upper and `/var/home` — they survive updates.

## What can go wrong (designed-for failure modes)

| Failure | Behavior |
|---|---|
| New image kernel-panics / never reaches graphical | Boot counter exhausts → systemd-boot falls back to previous UKI → previous slot boots |
| Power loss mid-update | Inactive slot half-written but its partition label is set **last** by sysupdate; UKI copied to ESP atomically (write + rename). Old version untouched → still boots |
| `/var` corruption | fsck via systemd-fsck in initrd; worst case reformat var = factory reset, OS itself unaffected |
| User remounts root rw | Impossible: EROFS is a read-only filesystem *format*, not a ro mount of a rw fs |
