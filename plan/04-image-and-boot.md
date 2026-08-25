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

Default sizes (build.conf): ESP 1 GiB (2 UKIs ≈ 2×250 MiB + slack — the boot splash pulled the
DRM modules into the initrd and took the UKI from ~105 MiB to ~242 MiB), root slots 6 GiB each,
var 4 GiB initial → ~17 GiB raw image, grows on first boot.

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

From the first DRM device to the Plasma Login Manager greeter the screen shows the Immos splash — the pulsing
logomark on `#0a0d11`, the wordmark, and a `<channel> · V<version> · AMD64` status line — drawn
over whatever the firmware left on screen. ESC switches to the boot log.

- **Theme:** plymouth's `script` plugin. Sources live in `config/branding/` as SVG (text, so the
  suite's CR-byte scan and `.gitattributes` stay happy); stage 40 rasterises them with
  `rsvg-convert` into `/usr/share/plymouth/themes/${ID}/` **before** dracut runs, because
  dracut's `45plymouth` module copies the theme out of the target into the initrd.
- **Cmdline additions:** see [01](01-architecture.md). `plymouth.ignore-serial-consoles` is the
  one that matters for CI.
- **Hand-off:** `plymouth-quit.service` tears the splash down, on **both** the desktop and
  `--console-only` images, with the `multi-user.target` drop-in guaranteeing the units are
  wanted. `plasmalogin.service` carries an `After=plymouth-quit-wait.service` drop-in so the
  greeter paints after the teardown rather than racing it.
  This is a regression against the GNOME image and a deliberate one: `gdm[plymouth]` conflicted
  with `plymouth-quit.service` and quit the splash itself with `--retain-splash` once the
  greeter had painted, so there was no black frame at all. Plasma Login Manager has no
  retain-splash equivalent. Restoring that hand-off is a [roadmap](08-roadmap.md) item.
- **UKI size:** the plymouth dracut module depends on dracut's `drm` module, so the initrd now
  carries the DRM kernel modules — the UKI went from ~105 MiB to ~242 MiB. Two of those is
  484 MiB of the 1 GiB ESP, which fits with room, but it is now the dominant ESP consumer.
- **dracut's `45plymouth` module is not sysroot-clean**, and both halves of that fail silently.
  It hands its payload to `plymouth-populate-initrd` without setting `PLYMOUTH_SYSROOT`, and
  that helper resolves the splash plugins' libraries with a non-sysroot-aware `ldd`. Stage 40
  therefore sets `PLYMOUTH_SYSROOT`/`PLYMOUTH_THEME_NAME`/`PLYMOUTH_PLUGIN_PATH` itself and
  passes the `libply*` libraries to dracut's own `--install`. Without the first, the initrd gets
  an empty theme directory and no plugins; without the second, `script.so` is present but
  `libply-splash-graphics.so.5` is not, `dlopen` fails, and plymouth falls back to a grey text
  splash with nothing logged anywhere. Stage 40 asserts both, including every `NEEDED` library
  of `script.so` and `drm.so`.
- **`.splash` section in the UKI: available, off by default.** `SPLASH_BACKEND` in `build.conf`
  selects `plymouth` (default, what v1 shipped), `stub`, `both`, or `none`. The stub image is
  composed by `config/branding/make-stub-bmp.py` from the same PNGs the theme uses, so the two
  cannot drift. What it buys and what it does not:
  - `systemd-stub` draws it **before the kernel starts**, which is the one window plymouth
    cannot reach — it needs a DRM device, and this kernel has no simpledrm (see [08](08-roadmap.md)).
  - It is drawn **once**, and it dies at the first modeset. There is no animation, no progress,
    and nothing redraws it: `stub` alone leaves the screen black from the first DRM driver all
    the way to the greeter, which is the majority of the boot. `both` is the combination that covers
    the whole timeline; `stub` alone is a downgrade, not a replacement.
  - The stub fills the screen **black** and blits the bitmap **1:1, centred, without scaling**
    (`src/boot/splash.c`). Hence `SPLASH_STUB_SCALE`, and hence the bitmap's black background
    rather than the theme's `#0a0d11` — a brand-coloured canvas would seam against the fill.
  - The section is measured into **PCR 11**. Changing the splash changes that measurement, so
    it matters to any future TPM-sealed policy the way the kernel and cmdline already do.
- **Plymouth is never uninstalled by any of this.** In all four modes it stays merged, its theme
  stays in `/usr/share/plymouth/themes/`, and it stays in the initrd with every stage-40
  assertion about its payload still enforced. "Off" is the single cmdline token its own unit
  already tests for: `ConditionKernelCommandLine=!plymouth.enable=0` on `plymouth-start.service`,
  which ships in both the initrd and rootfs copies. Switching backends is a rerun of stages
  40–60, not a rebuild.

## fstab (shipped in image, immutable lower)

```
PARTLABEL=var  /var   ext4   defaults,x-initrd.mount,x-systemd.growfs   0 2
PARTLABEL=esp  /efi   vfat   umask=0077,noauto,x-systemd.automount      0 2
tmpfs          /tmp   tmpfs  nosuid,nodev                               0 0
```

Root itself has no fstab entry (mounted by initrd from `root=PARTLABEL=root_<ver>`); the
`/etc` overlay is mounted by the dracut module, not fstab (rationale in 01).
