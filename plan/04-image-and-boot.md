# 04 — Image Assembly & Boot Media

## Loopless assembly (stage 60)

The entire disk image is built **without loop devices, without mounting anything** — every
filesystem tool used can populate from a directory. This makes the build work in any
privileged container (including Docker Desktop/WSL2, where loop devices are flaky) and is
inherently parallel-safe.

```
inputs:  /work/target (pruned rootfs)   out/uki/${ID}_${VER}.efi   config/build.conf sizes
outputs: out/${ID}-${VER}.img  (+ .img.zst)   out/release parts (erofs + uki, reused by 80)
```

Steps:

1. **Root image:** `mkfs.erofs -z lz4hc,12 -T0 --all-root out/root-${VER}.erofs /work/target`
   (zstd `-z zstd,15` is a build.conf option; lz4hc default favors runtime speed).
   `-T0` clamps timestamps for reproducibility.
2. **var image:** stage a `/work/var-staging` tree (flatpak store moved out of target's
   `/var/lib/flatpak`, overlay skeleton `overlay/etc/{upper,work}`, `home/`), then
   `mkfs.ext4 -d /work/var-staging -L var out/var.img ${VAR_SIZE_INITIAL}` — `-d` populates
   without mounting.
3. **ESP image:** `mkfs.vfat -n ESP out/esp.img ${ESP_SIZE}`, populate with `mtools`:
   `mmd`/`mcopy` of `systemd-bootx64.efi` → `EFI/BOOT/BOOTX64.EFI` + `EFI/systemd/`,
   `loader/loader.conf` (`timeout 0`, boot-counting on), and the UKI →
   `EFI/Linux/${ID}_${VER}.efi` (no tries-counter suffix in the factory image — see 01).
4. **Partition table:** compute offsets (1 MiB aligned), emit an `sfdisk` script:

   ```
   label: gpt
   p1: start=1MiB   size=${ESP_SIZE}       type=uefi  name=esp
   p2: start=…      size=${ROOT_SLOT_SIZE} type=root-x86-64  name=root_${VER}
   p3: start=…      size=${ROOT_SLOT_SIZE} type=root-x86-64  name=_empty
   p4: start=…      size=${VAR_SIZE_INITIAL} type=var  name=var
   ```

   `truncate -s ${TOTAL}` the image file, `sfdisk` it, then `dd conv=notrunc seek=<offset>`
   each filesystem image into its partition. Root slot B stays zeros.
5. **Compress:** `zstd -T0` → the distributable `.img.zst`. Zeros in slot B and var free
   space collapse; expected download ≈ 3.5–4.5 GiB for a ~17 GiB raw image.

GPT type UUIDs matter: root partitions use the discoverable-partitions **root (x86-64)** type
and var uses the **var** type, so systemd tooling (repart, gpt-auto for var fallback,
sysupdate `MatchPartitionType=root`) recognizes them.

Default sizes (build.conf): ESP 1 GiB, root slots 6 GiB each, var 4 GiB initial → ~17 GiB raw
image, grows on first boot.

The ESP budget is 2 UKIs plus slack, and the UKI has moved several times since it was sized —
every move driven by the boot splash. It first pulled the DRM modules into the initrd and went
from ~105 to ~242 MiB; dropping nouveau's GSP firmware brought it to 135.5 (plan/10);
[plan/11](11-kernel-boot-audit.md) cut 22 MiB of server CPU microcode and 100 initrd modules and
then spent +71.5 MiB adding the NVIDIA modules and *their* GSP firmware, for a measured
168.7 MiB. [plan/14](14-boot-splash-kms.md) removes the splash from the initrd entirely and takes
the whole graphics payload with it. `ESP_SIZE_MIB` has not changed through any of this.

## Boot media usage

Same artifact everywhere:

- **VM (QEMU):** `qemu-system-x86_64 -machine q35,accel=kvm -m 4G -cpu host -drive
  file=img,if=virtio -drive if=pflash,readonly=on,file=OVMF_CODE.fd -drive
  if=pflash,file=OVMF_VARS-copy.fd -device virtio-gpu -display gtk` — exact wrapper in
  `scripts/` (`run-vm.sh`, also used by stage 70). Convert with `qemu-img convert` for
  VMware/Hyper-V (`vhdx`)/VirtualBox (`vdi`) — raw GPT+UEFI boots in all of them.
- **Live/persistent USB:** `zstd -dc image.img.zst | dd of=/dev/sdX bs=4M` on Linux; on
  Windows, decompress then write with Rufus (dd mode) or balenaEtcher (which handles the
  decompressed `.img` directly). First boot grows `var` to the stick —
  this is a *persistent* live system, not a squashfs-toram live CD: same OS, same update
  mechanism, just on removable media.
- **Direct install:** dd the same image to an internal NVMe/SATA disk (from any live Linux).
  The future installer ISO (roadmap) automates exactly this + user setup.

First-boot sequence on any medium (details in 01): initrd `systemd-repart` extends the var
partition to the disk's end and fixes the backup GPT header; `x-systemd.growfs` expands
ext4; machine-id generated into the `/etc` overlay; Plasma Login Manager autologin → Plasma.

## ESP contents & bootloader policy

```
EFI/BOOT/BOOTX64.EFI          systemd-boot (fallback path — no NVRAM entry needed,
EFI/systemd/systemd-bootx64.efi   boots on any UEFI machine incl. removable media)
loader/loader.conf            timeout 0 (menu on-demand via key hold), default immos_*
EFI/Linux/immos_<ver>.efi   UKI(s) — Type #2 BLS entries; systemd-boot auto-discovers,
                              sorts by version, honors +tries boot counting
loader/entries.srel           (BLS marker)
```

- No NVRAM dependency: booting via the removable-media path (`EFI/BOOT/BOOTX64.EFI`) means
  the image needs **zero** `efibootmgr` setup — critical for dd-to-USB. On installed systems
  `bootctl install --graceful` from the updater can add a proper NVRAM entry (roadmap nicety).
- `bootctl` in the target (systemd `USE=boot`) provides: `set-default`/`set-oneshot`
  (manual rollback), `bless-boot` (via service), `status` (support/debug).
- Secure Boot: **off in v1** — README instructs disabling it; UKIs are unsigned. The layout
  is already UKI-based, so the roadmap path (sign UKIs + sd-boot, or shim) changes nothing
  structurally.

## os-release / image identity

`config/rootfs/etc/os-release` template (rendered in stage 40):

```
NAME="${DISTRO_NAME}"        ID=${DISTRO_ID}
VERSION_ID=${VERSION}         IMAGE_ID=${DISTRO_ID}
IMAGE_VERSION=${VERSION}      # ← sysupdate reads this as "current version"
ANSI_COLOR=...  HOME_URL=...  BUG_REPORT_URL=...
```

`IMAGE_ID`/`IMAGE_VERSION` are load-bearing: `systemd-sysupdate` uses them to know what's
installed; `ukify --os-release` stamps the same file into the UKI so systemd-boot shows a
proper menu title.

## Boot splash

From the firmware handing over to the Plasma Login Manager greeter the screen shows the Immos
splash — the logomark on `#0a0d11`, the wordmark, and a `<channel> · V<version> · AMD64` status
line. ESC reveals the boot log. Plymouth was removed in [plan/14](14-boot-splash-kms.md); the
full design and its rationale live there, and this is the summary.

**Two halves, because no single mechanism can cover the whole boot on this kernel.**
`gentoo-kernel-bin` has no `DRM_SIMPLEDRM` and no `CONFIG_FB_DEVICE`, so there is no
firmware-framebuffer DRM device and no `/dev/fb0` at all. Before the kernel starts, only the EFI
stub can draw; after it, only a DRM client can.

- **`systemd-stub` `.splash` section** — a BMP blitted by the stub before the kernel starts.
  systemd-stub fills the screen black and blits the bitmap **1:1, centred, without scaling**
  (`src/boot/splash.c`), which is why the canvas is black rather than the brand `#0a0d11` (a
  brand-coloured canvas would seam against the fill) and why `SPLASH_STUB_SCALE` exists: there is
  no resolution to query before `ExitBootServices`. The section is measured into **PCR 11**, so
  changing the splash changes that measurement the way the kernel and cmdline already do.
- **`<id>-splash`** — a static ~800-line C program on the read-only root, drawing on DRM with
  kernel uapi ioctls and no libdrm. Started by a udev rule the moment a `card*` device appears.

**The stub image now survives the whole initrd**, which it did not before: the initrd loads no
DRM driver any more, and `quiet` plus `CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER=y` means
nothing takes the framebuffer, so nothing modesets until after switch-root.

- **Assets:** `config/branding/` SVG sources (text, so the suite's CR-byte scan and
  `.gitattributes` stay happy). Stage 40 rasterises them with `rsvg-convert` into a **work
  directory**, and `make-splash-assets.py` composes both artefacts from those PNGs — the stub BMP
  and `/usr/share/<id>/splash.bin`, a container of opaque pre-composited BGRX tiles. Neither the
  SVGs nor the PNGs enter the image, so it needs no font and no image decoder at boot.
- **Hand-off:** there isn't one, and that is the point. The splash drops DRM master as soon as it
  has painted, so kwin can take master whenever it likes; the splash notices its CRTC is showing
  someone else's framebuffer and exits. No `Conflicts=`, no drop-ins, no ordering in either
  direction — plan/08 open question 6 and plan/11 finding 7 were both about machinery that no
  longer exists. Stage 40 removes the unit and udev rule on `--console-only`, where agetty owns
  the framebuffer.
- **UKI size:** this is where the change pays. The plymouth dracut module depended on dracut's
  `drm` module, so the initrd carried the DRM module tree plus every blob those drivers declare
  through `MODULE_FIRMWARE`, and plan/11 finding 4 added the NVIDIA modules and 98 MiB of GSP
  firmware on top. `--omit drm` removes all of it; stage 40 asserts no `drivers/gpu` module and
  no GSP firmware survives into the initrd.
- **`SPLASH_BACKEND`** in `build.conf` selects `both` (default), `stub`, `kms` or `none`. Nothing
  about the image changes with it except at most one cmdline token: the binary, its assets, its
  unit and its rule are installed in all four modes, and `ConditionKernelCommandLine=!<id>.splash=0`
  on the unit is the whole switch. Switching backends is a rerun of stages 40–60, not a rebuild.

## fstab (shipped in image, immutable lower)

```
PARTLABEL=var  /var   ext4   defaults,x-initrd.mount,x-systemd.growfs   0 2
PARTLABEL=esp  /efi   vfat   umask=0077,noauto,x-systemd.automount      0 2
tmpfs          /tmp   tmpfs  nosuid,nodev                               0 0
```

Root itself has no fstab entry (mounted by initrd from `root=PARTLABEL=root_<ver>`); the
`/etc` overlay is mounted by the dracut module, not fstab (rationale in 01).
