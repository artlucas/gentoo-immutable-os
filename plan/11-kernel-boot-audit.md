# 11 — Kernel, UKI and initrd audit (2026-08-25)

The follow-up to [plan/10](10-prune-audit.md) on the half it could not close. plan/10 took the
root EROFS down 20% and ended with one finding still open, stated as a heading: *"The UKI did not
shrink, and that is a finding."* This document is that finding chased down, plus the first
measured audit of what the boot artifact actually contains.

Everything below is measured against the real `0.2.2` artefacts in the `immos-work` volume — the
post-prune target and `initrd-0.2.2.img` — and every "after" number comes from a full dracut run
against a copy of that target with the changes applied, not from an estimate.

## Baseline: where the 135.5 MiB UKI goes

| | MiB |
|---|---|
| kernel (`vmlinuz-6.18.43-gentoo-dist-bin`) | 21.6 |
| **early CPIO — CPU microcode, uncompressed by design** | **34.8** |
| main initrd (`zstd -15`; 374 MiB uncompressed) | 78.9 |

…and inside the main image, 186 MiB of modules and 121 MiB of firmware.

Three things fall out of that, and only the third was expected.

**A quarter of the UKI is microcode that is never compressed.** `sys-firmware/intel-microcode`
installs 315 signature files, 34.5 MiB, covering every Intel CPU from the Pentium 4 to the current
Xeon. dracut's `--early-microcode` packs all of them into the early CPIO, which the kernel must
read before it can decompress anything and which is therefore stored raw. A byte saved there is a
byte off the ESP and off every A/B update — no compression ratio in between.

**The initrd carries hardware this image cannot boot from.** Fibre Channel HBAs (`lpfc`,
`qla2xxx`, `bfa`, `fnic`, `efct`), the SCSI and NVMe *target* stacks, NVMe-over-Fabrics,
InfiniBand, `drbd`, `dm-vdo`, `bcache`, the cluster and network filesystems, `mac80211` +
`cfg80211` in an initrd whose `network` module is omitted, the QuickAssist accelerators, and 126
in-kernel selftests. The initrd of this image mounts exactly two filesystems — the erofs root
named by `root=PARTLABEL=` and the ext4 `/var` carrying `x-initrd.mount` — both on a local GPT
disk, so none of that can be reached before switch-root by construction.

**NVIDIA machines get no splash before the root pivot**, which plan/08 already recorded as an
accepted tradeoff with the fix named. That one is now fixed, and it is the only change here that
makes the UKI bigger.

### Two things that look like levers and are not

**Modules are already stripped.** `strip --strip-debug` over the whole 623 MiB module tree
recovers 4 MiB: the `.ko` files carry `.symtab` and `.BTF` and no DWARF at all. There is no
debug-info win hiding in the module tree.

**Everything else is bounded by `gentoo-kernel-bin`.** The generic dist-kernel ships 4910 modules
and no `DRM_SIMPLEDRM`, and `/usr/src` is pruned, so module compression, a non-generic module set,
and closing plan/08's modeset-gap tradeoff all require `sys-kernel/gentoo-kernel` with a custom
config. That is a much larger commitment than this audit and is left as a roadmap item.

## Findings

### 1. The prune ran after dracut, so it only ever reached the root filesystem

`40-configure.sh` builds the initrd; `50-prune.sh` applies `config/prune-firmware.txt`; stage 40
runs first. The consequence, which plan/10 measured and could not fix in the same pass: the qcom
ARM SoC tree and the class-1 server-NIC firmware the image has *already decided it will never
load* were still on the ESP inside every UKI, and every update re-downloaded them.

**Fixed** by extracting the loop into `prune_hardware_trees()` in `scripts/lib/common.sh` and
calling it from stage 40 as section 2c, immediately before dracut. Stage 50 calls it again as an
idempotent guard so `--from 50` converges and its existing assertions keep meaning what they say.

It is deliberately *not* a new `35-` stage. `build.sh --from 40` is the documented way to rebuild
the UKI after a cmdline or splash change, and a separate stage would be skipped on exactly that
path — silently producing a UKI with the firmware back in it, which is the failure this finding
already is.

The bytes here are small (~6 MiB of `cxgb4`, `qed`, `qlogic` and `mediatek` firmware in the
initrd, most of which finding 3 removes anyway by dropping the modules that request it). Its value
is that `prune-firmware.txt` starts meaning what it claims — and that finding 2 becomes possible
at all.

### 2. Client-only microcode — 34.5 → 13 MiB, at 1:1 on the UKI

New `config/prune-microcode.txt`, same shape and same commenting discipline as
`prune-firmware.txt`: one `intel-ucode` signature prefix per line, in two labelled classes.

- **class 1, socket-server / Xeon Phi / server-Atom** (21.0 MiB): `06-ad` Granite Rapids (6.23,
  the largest single entry), `06-8f` Sapphire Rapids (5.75), `06-ae`, `06-af` Sierra Forest,
  `06-dd` Clearwater Forest, `06-cf` Emerald Rapids, `06-6a`/`06-6c` Ice Lake-SP/D, `06-55`
  Skylake-SP, the two Xeon Phi models, and the Atom C server parts.
- **class 2, pre-2015 and phone/tablet Atom SoCs** (1.9 MiB): Pentium 4 through Broadwell, plus
  Merrifield/Moorefield/SoFIA, which were never fitted to a PC at all.

Measured with the real function against the real tree: **207 of 315 signatures removed, 35 → 13
MiB**, and the early CPIO with it, **34.8 → 12.6 MiB**.

Three class-1 entries are arguable and go anyway, stated in the file rather than left to be
rediscovered: `06-8f` has Xeon W-2400/3400 workstation siblings, `06-55` shares a signature with
the Skylake-X/W HEDT parts, and `06-ae` is Granite Rapids-D. All three are outside the hardware
window the README states.

**Why this prune is safer than the firmware one, not riskier.** `prune-firmware.txt` warns that
getting it wrong produces a machine with no network. Microcode has no such failure mode: a CPU
whose signature is absent runs on the microcode its firmware already loaded. What is lost is the
OS-side errata update, not the ability to boot.

Four Atom-class *client* parts are kept deliberately — `06-37` Bay Trail, `06-4c` Braswell,
`06-5c` Apollo Lake, `06-7a` Gemini Lake — because plan/08 names them explicitly as in scope (they
are why the image has no AVX2 floor). The offline suite asserts none of the four is ever added to
the prune list, since pruning one would contradict a documented decision invisibly.

Stage 50 then deletes `/usr/lib/firmware/{intel,amd}-ucode` from the root filesystem entirely.
The UKI's early CPIO is the only copy anything reads: the kernel loads from it before any
filesystem is mounted, and the only consumer of the on-disk copy would be a late reload through
`/sys/devices/system/cpu/microcode/reload`, which nothing here does and no fwupd exists to do.

> **The ordering hazard that creates, and where it is caught.** Once stage 50 has deleted the
> tree, a later `build.sh --from 40` runs dracut against a stripped target and `--early-microcode`
> contributes nothing. The image boots perfectly and every CPU silently runs unpatched. Stage 40
> now asserts that the initrd it just built carries `GenuineIntel.bin` and `AuthenticAMD.bin`, so
> that path fails loudly instead of shipping.

### 3. `--omit-drivers` matches module NAMES, not paths

New `config/dracut-omit-drivers.txt`, 68 patterns in six classes, replacing the literal
`--omit-drivers "nouveau"` argument (which folds into class 6 unchanged).

The syntax had to be established empirically, because the flag does not do what its name suggests.
dracut wraps every entry as `^…$` and rewrites `-` to `_` (`dracut:2091,2099`), and
`dracut-install`'s `-N` compares against the module **name**. Tested directly against the
builder's dracut 111:

```
-N '^lpfc$'                  -> lpfc.ko excluded
-N '^drivers/scsi/lpfc/.*$'  -> lpfc.ko INSTALLED
-N '^.*scsi/lpfc.*$'         -> lpfc.ko INSTALLED
```

So a path-shaped entry is a silent no-op — no error, no warning, and the only symptom is a UKI
that did not shrink. The offline suite rejects any entry containing `/`, and stage 40 asserts
after the build that none of the 68 patterns matches a module that is actually in the initrd,
which is what turns a mistyped entry into a failed build.

Dashes normalise on *both* sides, which is worth recording because it is what makes the selftest
patterns possible: `-N '^.*_test$'` excludes `hid-uclogic-test.ko` as well as `fat_test.ko`.

The six classes and what each removes: FC/SAN/iSCSI-offload HBAs (13 MiB), the SCSI/NVMe target
stack and NVMe-oF (2), InfiniBand/RDMA (2.2), cluster and network filesystems (22, the largest —
`cifs`, `ocfs2`, `f2fs`, `kafs`, `ceph`, `gfs2`, `ubifs`, `9p` and the `sunrpc`/`rxrpc`/`netfs`
layer under them), clustered and layered block devices (3.5), and "dead or offload-only" (12 —
`nouveau`, the wireless stack, the `mt76` drivers stranded by its removal, `qed`/`cxgb4` which are
present only for their FCoE offload, QuickAssist, and the 126 in-kernel selftests).

Everything on that list stays in the **root** module tree. A user can still `mount -t cifs` after
boot; this is the initrd only.

Measured against the real initrd before the change, the patterns match 79 modules and — checked
explicitly — nothing load-bearing: `erofs`, `overlay`, `amdgpu`, `i915`, `xe`, `nvme`, `ahci`,
`usb_storage` and the nvidia trio are all untouched. The offline suite pins that last part with a
list of module names no pattern may ever match.

### 4. NVIDIA early KMS — the one change that makes the UKI bigger

plan/08's tradeoff read: *"NVIDIA machines get no splash until after the root pivot… the initrd
has no usable DRM device on NVIDIA at all: plymouth waits out `DeviceTimeout=8` and falls back to
text."* By decision, this is now fixed rather than accepted.

`--add-drivers "nvidia nvidia_modeset nvidia_drm"`, deliberately **not** `--force-drivers`: the
force variant writes a `modules-load.d` entry, which would load `nvidia.ko` on every AMD and Intel
machine too — a pointless probe and a resident driver on hardware it will never bind. Autoloading
is left to udev, which matches `nvidia.ko`'s PCI aliases.

That alone is not enough, and the missing piece is the reason this tradeoff survived so long:
**neither `nvidia-modeset` nor `nvidia-drm` has a modalias.** Nothing in sysfs ever names them, so
on a stock system they are loaded by whatever runs `modprobe nvidia-drm` first — the display
manager's udev environment, long after the initrd. New
`config/rootfs/usr/lib/modprobe.d/10-nvidia-drm.conf` adds `softdep nvidia post: nvidia-modeset
nvidia-drm`, and dracut copies `/usr/lib/modprobe.d` into the initramfs, so one file serves both
the initrd and the booted system. It is in `/usr/lib` rather than `/etc` because
`x11-drivers/nvidia-drivers` owns `/etc/modprobe.d/nvidia.conf` and a second file at that path
would collide on every driver bump.

**Cost, measured.** `nvidia.ko` 24.3 + `nvidia-modeset` 4.5 + `nvidia-drm` 0.5 MiB, and — the
expensive half — `nvidia.ko` declares `MODULE_FIRMWARE` for `gsp_tu10x.bin` (28.7) and
`gsp_ga10x.bin` (69.5), so dracut pulls 98 MiB of GSP firmware in behind them automatically.
**+71.5 MiB compressed**, nearly all of it firmware that compresses to only 84%.

`nvidia-uvm` and `nvidia-peermem` stay out — CUDA-only, 5.2 MiB, nothing in an initrd calls them.
`--add-drivers` pulls dependencies rather than siblings so this holds today; it is asserted anyway,
because "add the nvidia drivers" is exactly the line a future edit widens to a glob.

No cmdline change was needed. `nvidia-drm.modeset=1` is already there, and the shipped
`/etc/modprobe.d/nvidia.conf` documents that `nvidia-drm fbdev` defaults to on in 595.

> **If this ever needs to be cheaper**, the half-measure is to stash `gsp_tu10x.bin` aside for the
> duration of the dracut call: Turing keeps working and just loses its early splash, and the UKI
> drops ~21 MiB. Not taken, because it is file surgery behind Portage's back, which is the shape
> this pipeline otherwise avoids.

### 5. Initrd compression: dracut's default is `zstd -15`

`--compress "zstd -19 -T0"`. Measured on the trimmed tree, 69.9 → 61.2 MiB. It costs build time
and nothing else — dracut's own `check_kernel_compress_support` already guards whether the kernel
can read zstd at all, and the level does not change that answer.

### 6. Dead modules in the root filesystem — 129 files, 26 MiB

Not a general module prune; that is explicitly out of scope (see "Not done"). These are modules
that *cannot* load on this image, not ones that are merely unlikely to:

| | MiB | why it cannot load |
|---|---|---|
| `nouveau.ko` + `mxm-wmi.ko` | 7.6 | blacklisted unconditionally by `/etc/modprobe.d/nvidia.conf`, not built for by `VIDEO_CARDS`, and its GSP firmware is already gone via `prune-firmware.txt` class 3 |
| the 126 in-kernel selftests | 13.4 | `test_bpf`, `ext4-inode-test`, `fat_test`, the KUnit framework and its per-subsystem helpers. Loaded by a harness no image ships |
| `kheaders.ko` | 4.5 | `CONFIG_IKHEADERS` exists to hand the running kernel's headers to a BPF or systemtap build; plan/06 guarantees there is no compiler |

Measured against the real tree: 129 files, `usr/lib/modules` 623 → 597 MiB.

The sweep is surgical in a way worth recording, because the obvious wider glob is wrong:
`ch7006.ko` and `sil164.ko` live under `drivers/gpu/drm/nouveau/` but are independent I2C TV-encoder
and DVI-transmitter drivers that do not depend on nouveau. Matching `nouveau.ko` by name rather
than deleting the directory keeps them, and `depmod` confirms nothing else references the module
that left.

**`depmod -b "$T" "$KVER"` afterwards is not optional**, and the failure it prevents is a
confusing one: `modules.dep` and `modules.alias` still name every deleted file, and modprobe turns
a stale dependency line into "module not found" for the module that *depended* on the missing one
rather than for the one actually gone. Section 4 asserts no `modules.dep` entry resolves to a
missing path.

This section runs **after** 3e, the dangling-symlink sweep, and the ordering is deliberate. Until
3e has run, the module directory still holds the `System.map`, `config` and `vmlinuz` symlinks
pointing into the `/usr/src` tree section 3 deleted. depmod survives them and exits 0, but prints
three `ERROR: fstatat(3, System.map): No such file or directory` lines into the build log —
alarming, meaningless, and the kind of thing that costs somebody an hour. Verified silent in the
new order.

### 7. The greeter hand-off, and the design that did not work

plan/08 open question 6: `plymouth-quit.service` tears the splash down and `plasmalogin.service`
is merely ordered after `plymouth-quit-wait.service` — deterministic, but visibly black between
the two, because a plain `plymouth quit` resets the console.

**The obvious fix does not port from GDM.** `gdm.service` carries
`Conflicts=plymouth-quit.service` and quits the splash itself with `--retain-splash`. Transplanting
that shape onto `plasmalogin.service` fails twice over:

- `kde-plasma/plasma-login-manager`'s own unit already ships
  `After=… plymouth-quit.service …`. `Conflicts=` plus that ordering is a race, not a guarantee:
  `plymouth-quit.service` is pulled by `multi-user.target` with no ordering against
  `graphical.target`, so on any boot where it wins it resets the console before the greeter is
  even queued.
- Adding `After=plymouth-quit-wait.service` on top of an `ExecStartPre` that is now the *only*
  thing that ever quits plymouthd deadlocks the two units against each other: quit-wait blocks
  until plymouthd exits, and plymouthd exits only from a unit ordered after quit-wait.

**What was done instead** changes the teardown rather than who performs it: a drop-in on
`plymouth-quit.service` replacing its `ExecStart` with `plymouth quit --retain-splash`. That skips
the console reset, so the last frame stays on the framebuffer until kwin paints over it. Every
existing ordering is untouched, there is no new dependency, and `plasmalogin.service.d/10-plymouth.conf`
keeps its original `After=plymouth-quit-wait.service` exactly as it was.

The empty `ExecStart=` reset is load-bearing and asserted: `ExecStart` is additive in a
`Type=oneshot` unit, so without it systemd would run the vendor's plain `plymouth quit` first and
reset the console anyway.

Stage 40 removes the drop-in on `--console-only` images. There the next thing to touch the screen
is agetty, which renders its login prompt into the same framebuffer — a retained splash would sit
behind the text rather than being replaced by a greeter.

**Nothing in this repo can verify this.** Stage 70 reads a serial port, so an image that flashes
black reports green. It needs an eyeball in QEMU.

### 8. `rd.emergency=reboot` — automatic rollback that is actually automatic

An initrd that cannot find or mount the root filesystem currently drops to a dracut emergency
shell and sits there. The machine has consumed a boot *attempt* — systemd-boot decremented the
entry's tries counter when it booted it — but never finishes one, so a bad slot needed three
manual power cycles before sd-boot gave up and fell through to the previous UKI. That is the
opposite of what plan/01's Automatic Boot Assessment is for.

`rd.shell=0 rd.emergency=reboot` on the cmdline spends those three tries by itself, in seconds.
Behind `DEBUG_INITRD` in `build.conf` (default 0) because the tradeoff is real and worth stating:
`loader.conf` sets `editor no` and the cmdline lives inside the UKI, so on an image built with 0
there is no way to ask for the shell at boot time. Getting it back is a rerun of stages 40–60.

### 9. `KVER` was picked in readdir order

`40-configure.sh` determined the kernel version with `find … -maxdepth 1 -type d | head -n1` —
an arbitrary pick if the target ever held two module trees. It would have built a UKI whose kernel
and module set disagree, and nothing downstream would notice: the image builds, boots as far as
the initrd, and then has no drivers. Both stage 40 and stage 50's new module work now count the
directories and die on anything but exactly one.

## Result, measured end to end

A full dracut + ukify run against a copy of the 0.2.2 target with every change applied:

| | 0.2.2 | after | Δ |
|---|---|---|---|
| early CPIO (microcode) | 34.8 | **12.6** | −22.2 |
| main initrd | 78.9 (`zstd -15`) | **134.4** (`zstd -19`) | +55.5 |
| **UKI** | **135.5** | **168.7** | **+33.2** |
| modules in the initrd | 835 | **735** | −100 |
| Intel microcode signatures | 315 | **108** | −207 |

The UKI grows, and all of the growth is finding 4: the NVIDIA payload is +71.5 MiB against −38.3
from everything else. Without it the UKI would be ~97 MiB, down 28%. That was a decision, taken
with these numbers in hand — an NVIDIA machine that shows the splash from the first modeset is
worth more than 33 MiB of ESP.

Two UKIs on the 1 GiB ESP is 337 MiB, so `ESP_SIZE_MIB` does not move; headroom drops from 7.5×
to 3×.

Root-filesystem side, measured the same way: `usr/lib/firmware` 1000 → 965 MiB (the microcode
leaves entirely once the UKI carries it) and `usr/lib/modules` 623 → 597 MiB, with `depmod`
silent and `modules.dep` naming no file that is not there.

Verified in the produced initrd: both microcode blobs in the early CPIO; all three nvidia modules
plus `gsp_ga10x.bin` and `gsp_tu10x.bin`; the modprobe softdep; `erofs.ko` and `overlay.ko` still
present (`ext4` is builtin in this kernel and correctly absent); plymouthd, the theme, `script.so`
and the DRM renderer intact; `nvidia-uvm` absent; and zero of the 68 omit patterns matching any of
the 735 modules. `firmware/cxgb4`, `qed`, `qlogic`, `mediatek`, `cavium` and `advansys` are gone
from the initrd, and `firmware/intel` fell 6.36 → 2.71 MiB.

## Not done (recorded, with numbers)

- **`linux-firmware[compress-zstd,deduplicate]`** — plan/10 finding 1, −581 MiB installed and
  −135 MiB EROFS, still open. Kept separate deliberately: it is a USE-flag change, so stage 30's
  staleness guard forces a full rebuild, while everything in this document is a stages 40–60
  rerun. It interacts — pre-compressed firmware makes the initrd's copy ~15 MiB larger — and
  finding 3 more than pays for that.
- **A `prune-modules.txt` for the root filesystem.** InfiniBand (16 MiB), the DVB tuners inside
  `drivers/media` (52), enterprise NIC families and SAN HBAs are ~130 MiB installed and ~50 MiB of
  EROFS on the same reasoning as `prune-firmware.txt`. Out of scope by decision; finding 6 takes
  only what is dead by construction.
- **Leaving `gentoo-kernel-bin`.** See "Two things that look like levers" above. `DRM_SIMPLEDRM`
  would close plan/08's remaining modeset-gap tradeoff, and a non-generic module set would be worth
  far more than anything in this document — at the cost of owning a kernel config.
- **`SC2115` in `50-prune.sh:189`** (`rm -rf -- "$slot"/{include,share,bin}`) is pre-existing and
  untouched; `$slot` comes from a glob and cannot be empty. Noted so the next shellcheck run
  knows it is not new.

## Status

| # | Change | Effect | Status |
|---|---|---|---|
| 1 | prune firmware/microcode before dracut (`prune_hardware_trees`) | enables 2; closes plan/10's open finding | done |
| 2 | `config/prune-microcode.txt`, client-only signatures | −22.2 UKI, −22 root | done |
| 3 | `config/dracut-omit-drivers.txt`, 68 name patterns | −100 modules, −56.7 uncompressed | done |
| 4 | NVIDIA early KMS + modprobe softdep | +71.5 UKI; splash on NVIDIA from first modeset | done |
| 5 | initrd `zstd -19` | −8.7 on the trimmed tree | done |
| 6 | dead modules + `depmod` | −26 root (129 files) | done |
| 7 | retain-splash teardown | no black frame at the greeter | done, **needs a visual check** |
| 8 | `rd.emergency=reboot` behind `DEBUG_INITRD` | rollback without three power cycles | done |
| 9 | `KVER` guard in stages 40 and 50 | correctness | done |

Findings 7 and 4 are the two that no automated test in this repo can see — stage 70 reads a serial
port, so a black screen and a perfect splash are indistinguishable to it. Both need QEMU
(`scripts/run-vm.sh`), and finding 4 needs real NVIDIA hardware to confirm the thing it was built
for.
