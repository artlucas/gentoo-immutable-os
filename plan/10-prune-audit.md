# 10 — Prune audit of the 0.2.0 image (2026-08-25)

A measured, package-by-package audit of what the shipped `immos 0.2.0` image actually carries,
what holds each item in, and what can leave. It is the follow-up plan/06 asks for and could not
do: plan/06's own numbers stop at ten `du` rows, and its one named finding — the orphaned
Python cluster — turns out to be worth **1.8 MiB**, not the "real, actionable finding" it is
billed as. The real weight is somewhere else entirely.

Everything below is measured against `out/immos_0.2.0.root.erofs` and the post-prune target in
the `immos-work` volume, not estimated.

## Baseline

| | Measured |
|---|---|
| target tree after stage 50 | 8362 MiB installed |
| …of which owned by a package | 5784 MiB |
| …`/var` (flatpak preinstall) | 2495 MiB |
| root EROFS (lz4hc,12) | **3381 MiB** |
| root EROFS `.zst` — the A/B payload | 2519 MiB |
| full disk `.img.zst` | 3497 MiB |
| packages in the shipped image | 615 |

**Rank by shipped size, not installed size.** plan/06 already records that the prune's installed
win does not translate to the EROFS, and the audit confirms why: the two are almost independent.
Compressibility measured per tree (`zstd -15`, a stand-in for "how much of this survives into the
download"):

| Tree | installed | compresses to |
|---|---|---|
| `usr/share/wallpapers` | 255 MiB | **99%** — PNG/JPEG, already compressed |
| `usr/lib/firmware/nvidia` (nouveau GSP) | 148 MiB | 69% |
| `usr/lib/firmware/mediatek` | 70 MiB | 52% |
| `usr/share/fonts` (all) | 841 MiB | 49% |
| `usr/lib/firmware/qcom` | 456 MiB | 41% |
| `usr/share/fonts/noto` | 440 MiB | 35% |
| nvidia CUDA/OptiX libraries | 379 MiB | 30% |
| `usr/share/locale` | 77 MiB | 26% |
| `usr/lib/modules` | 608 MiB | 17% |
| `usr/share/icons/breeze*` | 60 MiB | **13%** |

A megabyte of wallpaper costs the user ~7× what a megabyte of Breeze icons costs. The 82 MiB
`breeze-icons` row that stands out in an installed-size listing is 8 MiB of download and is not
worth touching; the 217 MiB of wallpaper is 216 MiB of download and is.

`zstd -15` is only the screening metric. Every tree that made it into the recommendations was then
rebuilt into a real EROFS with the build's own `mkfs.erofs -zlz4hc,12` and measured, and those are
the numbers quoted per finding.

## Method (reproducible)

Stage 50 deletes the VDB, so the shipped image cannot be queried with Portage. It can be
reconstructed: every package in the image was merged from a gpkg in the `immos-cache` volume,
and each gpkg carries the full VDB metadata for exactly the build that shipped.

1. For each CPV in `out/reports/target-packages-cpv.txt`, extract `metadata.tar.zst` from
   `/cache/binpkgs/<cat>/<pn>/<pf>-*.gpkg.tar` into `$FAKEROOT/var/db/pkg/<cat>/<pf>/`.
2. Refresh `RDEPEND`/`PDEPEND` from the pinned tree's `metadata/md5-cache` so the graph matches
   `SNAPSHOT_DATE`, and blank `DEPEND`/`BDEPEND`/`IDEPEND` — the image is the RDEPEND closure and
   nothing else.
3. Copy `world_sets` from the target (`@base @desktop @hardware`).
4. `ROOT=$FAKEROOT PORTAGE_CONFIGROOT=/work/config emerge --depclean --pretend --with-bdeps=n`,
   or walk the graph directly with `portage.dep.use_reduce` against each package's recorded `USE`.

Two IDEPEND-only atoms (`sys-kernel/installkernel`, `app-eselect/eselect-mpg123`) have to be
stubbed into the **builder's** `/var/db/pkg` for depclean to resolve — IDEPEND is checked against
`BROOT`, not `ROOT`. Their absence from the image is correct, not a bug.

Per-package installed size comes from listing each gpkg's `image.tar.zst` and intersecting the
paths with the real post-prune tree (normalising `lib/` → `usr/lib/` for merged-`/usr`). Anything
the prune already deleted then scores zero, so the numbers below are what *ships*.

## Corrections to plan/06

**The orphaned Python cluster is 1.8 MiB, not a lever.** plan/06 says thirteen of the twenty
surviving `dev-python/*` packages are held by `app-portage/gemato` and the setuptools stack and
that adding them to stage 50's unmerge loop "is the obvious next trim". Re-running the
reachability analysis with stage 50's existing unmerge list applied gives fifteen newly-orphaned
packages totalling **1.78 MiB**:

```
dev-python/{requests,urllib3,idna,charset-normalizer,certifi,pysocks}
app-misc/pax-utils  sys-apps/sandbox  sys-apps/install-xattr  dev-util/debugedit
acct-user/portage  acct-group/portage  acct-group/jobserver
```

Worth doing for hygiene — an image with no Portage should not ship Portage's sandbox, its
`install-xattr` shim or its user accounts — but it is a rounding error in bytes, and it should
not be described as the next trim.

**`setuptools` and the jaraco stack are not orphans.** plan/06 lists
`dev-python/{setuptools,packaging,platformdirs,more-itertools,jaraco-*}` as part of the same
orphan cluster. They are not: `dev-libs/gobject-introspection` RDEPENDs `dev-python/setuptools`,
and g-i is held by `dev-python/pygobject` ← `sys-power/power-profiles-daemon` (a `@desktop`
member) and by `net-libs/libqrtr-glib` ← `modemmanager` ← `networkmanager`. They stay as long as
either chain does, and unmerging them would leave a broken dependency in the image.

**The documented perl escape hatch no longer removes perl.** plan/06 says setting
`kde-apps/kio-extras -samba` makes "samba, perl and Parse-Yapp all leave the image together".
Under Plasma that is no longer true: `sys-apps/lm-sensors` RDEPENDs `dev-lang/perl`
unconditionally (for `sensors-detect`), and lm-sensors is pulled by `kde-plasma/libksysguard` and
`kde-plasma/ksystemstats` — i.e. by the System Monitor, which is in `@desktop`. Dropping samba
frees 36.1 MiB (samba 31.7, mit-krb5 3.3, cifs-utils, the talloc/tdb/tevent trio and Parse-Yapp);
`dev-lang/perl` (47.4 MiB) stays regardless. The interpreter-policy note in `50-prune.sh` should
say so, because the flag no longer buys what it claims to.

## Findings

Ordered by shipped-size impact. "Frees" is post-prune installed size unless stated.

### 1. `sys-kernel/linux-firmware[compress-zstd]` — −857 MiB installed, −220 MiB in the EROFS

The single largest item in the image is 1629 MiB of firmware, and the kernel that ships with it
can already read it compressed:

```
$ grep FW_LOADER_COMPRESS <gentoo-kernel-bin-6.18.43 .config>
CONFIG_FW_LOADER_COMPRESS=y
CONFIG_FW_LOADER_COMPRESS_XZ=y
CONFIG_FW_LOADER_COMPRESS_ZSTD=y
```

Measured end to end — copy the tree, `zstd -9` every file (what the ebuild's `--zstd` does), then
build an EROFS from each with the shipped `-zlz4hc,12`:

| | installed | inside the EROFS |
|---|---|---|
| firmware as shipped today | 1629 MiB | 980 MiB |
| firmware with `compress-zstd` | 772 MiB | **760 MiB** |

Zero hardware-compatibility loss — every blob is still there, the kernel decompresses on load.
`-initramfs` is already set, so nothing changes for dracut. Combining with `deduplicate` (which
symlinks the 86.9 MiB of byte-identical blobs the tree currently carries) is legal — the ebuild's
`REQUIRED_USE` only forbids `savedconfig` + `deduplicate`.

This is the highest-value single flag in the audit and it costs nothing but a rebuild.

### 2. ARM SoC platform firmware — −475 MiB installed, −284 MiB in the EROFS

`usr/lib/firmware/qcom` is 458 MiB, and on an amd64-only image essentially none of it can ever
load. It is Snapdragon **platform** firmware: ADSP/CDSP/modem/GPU-zap blobs for phone, laptop-ARM,
automotive and IoT SoCs.

```
102 qcom/x1e80100   28 qcom/sm8250   27 qcom/kaanapali  26 qcom/vpu       26 qcom/sa8775p
 26 qcom/qcs6490    25 qcom/sdm845   24 qcom/qrb4210     21 qcom/sm8750    21 qcom/qcm2290
 20 qcom/glymur     18 qcom/apq8096  17 qcom/qcs8300     17 qcom/qcm6490   16 qcom/qdu100 …
```

The x86-relevant Qualcomm hardware — Atheros/Qualcomm Wi-Fi and Bluetooth — lives in `ath10k`,
`ath11k`, `ath12k`, `qca` and `rtw89`, which are separate top-level directories and are untouched.
`prune-firmware.txt` already removes `qcom/sc8280xp` on exactly this reasoning; the entry should
be the whole `qcom` directory. The two arguable exceptions are `qcom/aic100` (5 MiB, a PCIe AI
accelerator that can sit in an x86 box) and `qcom/venus-*` (ARM video), both cheap to keep.

`mediatek` (71 MiB) is the same shape but must **not** go wholesale: `mt7915`, `mt7916`,
`mt7925`, `mt7927`, `mt7981`, `mt7986`, `mt7987`, `mt7988` and `mt7996` are Wi-Fi parts, and
`mt7925`/`mt7927` in particular are the Wi-Fi 7 M.2 modules shipped in x86 laptops. Only the
`mt8xxx` Chromebook/tablet SoCs go — eight directories, 21 MiB.

**Implemented 2026-08-25** in `config/prune-firmware.txt`, which now carries the reasoning in two
labelled classes (server/datacenter hardware, ARM SoC platform firmware) and an explicit warning
that vendors ship laptop radios alongside their SoC blobs. The `qcom/sc8280xp` entry it grew out
of is gone, subsumed by the whole-directory entry. Verified against the real tree: the new
entries resolve to 479 MiB, and `ath10k`, `ath11k`, `ath12k`, `qca`, `rtw89` and every
`mediatek/mt79*` survive untouched.

**Findings 1 and 2 are not additive** — compressing what is left is worth less than compressing
everything. All four cells measured against the committed prune list, same
`mkfs.erofs -zlz4hc,12` the build uses:

| firmware | installed | EROFS |
|---|---|---|
| as shipped | 1629 | 980 |
| ARM platform firmware pruned | 1154 | 696 |
| `compress-zstd` only | 772 | 760 |
| **both** | **573** | **561** |

Together: **−1056 MiB installed, −419 MiB off the EROFS**, and every piece of hardware the image
supports today still has its firmware.

#### Does compressing it cost boot time? Measured: no, it saves ~80 ms

The obvious objection is that the kernel now has to decompress at driver-probe time. It does, and
it is cheap — but the reason the net is *negative* is that `40-configure.sh` runs dracut with
`--no-hostonly`, so **the initrd carries a second full copy of `/usr/lib/firmware`**: 275 MiB of
the 525 MiB initramfs. That whole thing is unpacked into tmpfs on every boot before anything else
runs, and compressing the firmware shrinks it.

| | today | with `compress-zstd` |
|---|---|---|
| initramfs payload | 525 MiB | 413 MiB |
| …of it firmware | 275 MiB | 163 MiB |
| unpack time | 507 ms | **420 ms** |
| firmware decompressed at probe time | 0 ms | **6–8 ms** |

The probe-time figure is the firmware a real machine actually asks for, not the whole tree —
measured over an Intel laptop set (i915 DMC + GuC, SOF, Bluetooth), an AMD desktop set (one ASIC's
`gc`/`psp`/`vcn`/`sdma`/`dcn`/`smu`) and a Wi-Fi + Bluetooth set. Each lands at 6–8 ms; zstd
decompresses at ~1.35 GiB/s on one core, and no realistic per-boot set exceeds ~10 MiB. Against
that, probe-time reads off the EROFS roughly halve, and ~112 MiB less tmpfs is held until
switch-root.

Two details that look like they should matter and do not:

- **The double lookup is real but free.** The shipped kernel's own Kconfig says it plainly —
  *"The compressed file is loaded as a fallback, only after loading the raw file failed at first."*
  So every `request_firmware()` costs one extra `-ENOENT` per search path before it finds the
  `.zst`. That is a negative dentry lookup, microseconds, a few dozen times per boot.
- **The one blob big enough to matter is not affected.** `nvidia/595.91.07/gsp_ga10x.bin` is
  69.5 MiB and takes 48 ms to decompress — but it is installed by `x11-drivers/nvidia-drivers`,
  not `sys-kernel/linux-firmware`, so this flag never touches it. It also only compresses to 84%,
  so it would not be worth compressing even if it could be.

**The one genuine cost is the UKI, and it grows.** Repacking the initrd with pre-compressed
firmware takes it from 184 MiB to ~199 MiB: `zstd -9` on 4227 separate small files cannot exploit
the cross-file redundancy that dracut's single solid stream does, so compressing twice loses
~15 MiB. That is a **−418 MiB EROFS against a +15 MiB UKI**, and both ship in every update.

Nothing here is visible to stage 70 — its QEMU guest is virtio and requests no firmware at all, so
a boot-time regression in this area could never appear in the smoke test. The timings are
userspace `zstd` on the build host rather than the kernel's in-tree decompressor on target
hardware; the *ratio* between the two columns is the robust part, not the absolute milliseconds.

> **Adjacent finding, larger than this one.** `--no-hostonly` means the firmware tree ships
> **twice** — once in the root EROFS and once inside the UKI — and both are in the release
> directory (`immos_0.2.0.efi` is 252 MiB next to a 2519 MiB `root.erofs.zst`). Every A/B update
> downloads that duplicate. Whether the initrd needs the full tree, or only the storage and
> display drivers required to reach switch-root, is a separate question worth its own audit; a
> `--hostonly-mode sloppy`-style middle ground or an explicit `--omit-drivers` list would cut the
> UKI by well over half. Not attempted here because getting it wrong produces a machine that does
> not boot on hardware the smoke test does not model.

### 3. `media-fonts/noto[-extra]` — −335 MiB installed, −222 MiB in the EROFS

`media-fonts/noto` is 440 MiB and `+extra` is on. The flag does exactly one thing:

```bash
use extra || rm -rf "${ED}"/usr/share/fonts/noto/Noto*{Condensed,SemiBold,Extra}*.tt[f,c]
```

That is **1550 of the package's 2177 files** — and it is entirely extra *weights and widths*
(Condensed, SemiBold, ExtraLight, ExtraBold) of scripts the image already has. Script coverage,
which plan/06 names as the reason fonts are left alone, is untouched: every
`NotoSans-*`/`NotoSerif-*` family survives. Arch makes the same split for the same reason.

| `/usr/share/fonts/noto` | installed | EROFS |
|---|---|---|
| as shipped (`+extra`) | 445 MiB | 291 MiB |
| `USE=-extra` | 110 MiB | **69 MiB** |

This is the cheapest large win in the audit — no capability is lost at all, only font variants
nothing in the default theme selects. Two thirds of it lands in the download, because lz4hc only
gets TTF outlines to 65% and the rest was still sitting in the EROFS. (Note the gap with the
`zstd -15` screening figure of 35% above: fonts are the tree where the block-oriented lz4hc the
build uses falls furthest behind a solid stream. If EROFS compression is ever revisited,
`EROFS_COMPRESSION="zstd,15"` is already a `build.conf` switch and fonts are where it would pay.)

**Implemented 2026-08-25** as `media-fonts/noto -extra` in `config/portage/package.use/image`.
This is the only one of the five implemented fixes that changes a package's build, so it is the
one that forces a rebuild: stage 30's staleness guard refuses to reuse a target whose config
fingerprint moved. The package *set* does not change, so `expected-packages.txt` stays as it is.

### 4. Flatpak locale scoping — −655 MiB out of `/var`

`/var` is 2495 MiB, and it is one Firefox:

| ref | MiB |
|---|---|
| `org.freedesktop.Platform.Locale/x86_64/25.08` | **824** |
| `org.freedesktop.Platform/x86_64/25.08` | 556 |
| `org.freedesktop.Platform.GL.default/x86_64/25.08` | 437 |
| `org.mozilla.firefox/x86_64/stable` | 320 |
| `org.freedesktop.Platform.GL.default/x86_64/25.08-extra` | 87 |
| `org.mozilla.firefox.Locale/x86_64/stable` | 48 |
| `org.freedesktop.Platform.codecs-extra/x86_64/25.08-extra` | 42 |

The image ships **872 MiB of Flatpak translations for every language on Flathub** while
`build.conf` says `LOCALES_KEEP="en de fr es pt_BR it ja zh_CN ru"` and stage 50 deletes the rest
of `/usr/share/locale` on exactly that list. `/var/lib/flatpak/repo/config` has no `xa.languages`
key, which is what tells flatpak which `.Locale` subpaths to pull.

**Exact saving, measured against the deployed extensions:** `Platform.Locale` 824 → 209 MiB
(−615) and `firefox.Locale` 48 → 8 MiB (−40). **−655 MiB**, not the −750 first estimated: the
nine kept languages are not all small (`de` alone is 91 MiB).

**Implemented** in `40-configure.sh`, immediately after `flatpak remote-add` and before any
install. Two details the first sketch of this fix got wrong:

- **The subpaths are bare language codes.** The deployed extension has `pt` and `zh`, never
  `pt_BR` or `zh_CN`, and no `en` at all — English lives in the runtime itself. So the region
  suffix is stripped rather than passed through: `en de fr es pt_BR it ja zh_CN ru` becomes
  `de;en;es;fr;it;ja;pt;ru;zh`. flatpak tolerates the longer form (it derives the base language
  itself), but the stored config would then name subpaths that do not exist.
- **It must be set unconditionally, not only in `build` mode.** The key lands in
  `/var/lib/flatpak/repo/config`, which ships, so the firstboot preinstall unit and every later
  `flatpak install` the user runs inherit it.

The value is read back with `flatpak config --get` and the build dies if it did not take — a
silently-unset key costs 655 MiB and is invisible until someone measures `/var`, which is the
same failure shape plan/06 records for the size report itself.

This affects the disk `.img`/`.img.zst`, not the A/B root payload — `/var` is created once at
install — but it is the largest single number in the whole audit and it is a config key, not a
deletion.

### 5. Wallpapers — −193 MiB installed and shipped

`kde-plasma/plasma-workspace-wallpapers` is 217 MiB, `/usr/share/wallpapers` 255 MiB with Breeze's
own, and it compresses at **99%** — this is the most expensive tree in the image per byte
downloaded. It breaks down by resolution:

| variant | MiB | files |
|---|---|---|
| 5120x2880 | 131.7 | 26 |
| 7680x2160 | 61.1 | 8 |
| 3840x2160 | 23.9 | 6 |
| 1440x2960 | 13.6 | 6 |
| 1080x1920 | 12.8 | 14 |
| 2560x1600 | 8.1 | 14 |

Deleting the `5120x2880` and `7680x2160` variants leaves every wallpaper present and 4K-capable —
Plasma picks the closest-fitting image from the set and will render 3840x2160 on a 5K panel:

| `/usr/share/wallpapers` | installed | EROFS |
|---|---|---|
| as shipped | 256 MiB | 254 MiB |
| resolution ceiling at 3840x2160 | 63 MiB | **62 MiB** |

A `prune-wallpapers.txt`-style resolution ceiling in stage 50 is the natural shape, matching
`prune-firmware.txt`.

Dropping the package outright frees 217 MiB and is the only entry here with no reverse
dependency at all (it is a bare `@desktop` member), but it leaves the wallpaper picker nearly
empty, so the resolution trim is the better trade.

### 6. `kde-apps/thumbnailers[-pdf]` — −137 MiB

The image ships Ghostscript, two font packages and a TeX fragment, and the entire reason is one
Dolphin thumbnailer:

```
media-fonts/arphicfonts 68.1 ─┐
media-fonts/urw-fonts   17.1 ─┤
app-text/poppler-data   12.3 ─┼─ app-text/ghostscript-gpl 37.8 ─ media-gfx/kio-ps-thumbnailer 0.09
app-text/dvipsk          0.6 ─┤                                    └─ kde-apps/thumbnailers ─ dolphin
dev-libs/kpathsea        0.3 ─┘
media-libs/jbig2dec / net-dns/libidn
```

`thumbnailers`'s `pdf` flag (on by the profile) pulls `kio-ps-thumbnailer`, which hard-RDEPENDs
`ghostscript-gpl` and `dvipsk`. **Nothing else in the image uses Ghostscript** — there is no
`net-print/cups-filters`, and `net-print/cups` and `kde-plasma/print-manager` do not depend on it,
so printing is unaffected either way. `kde-apps/thumbnailers -pdf` frees 136.8 MiB across nine
packages; the cost is PostScript/PDF thumbnails in Dolphin.

**If that cost is unacceptable, take 68.1 MiB of it for free.** `arphicfonts` is pulled by
`ghostscript-gpl[l10n_zh-CN]`, which is on only because `zh_CN` is in `LOCALES_KEEP` and therefore
in `L10N`. Setting `app-text/ghostscript-gpl -l10n_zh-CN -l10n_zh-TW` drops the largest item in the
chain and keeps the thumbnailer; what is lost is Chinese glyph substitution when Ghostscript
rasterises a CJK PostScript file that does not embed its fonts.

### 7. `dev-qt/qtspeech[-speechd]` — −50 MiB

`kde-frameworks/ktexteditor` RDEPENDs `dev-qt/qtspeech` unconditionally, `qtspeech`'s `+speechd`
pulls `app-accessibility/speech-dispatcher`, and that drags espeak-ng, sox, libmad, gsm,
pcaudiolib, dotconf and pyxdg — **50.2 MiB across eight packages**, plus 51 MiB of
`/usr/share/{speech-dispatcher,espeak-ng-data}` inside them.

The only consumer is `libKF6TextEditor`'s "speak text" action, and the image ships no text editor
— ktexteditor is present solely as a `plasma-workspace` dependency. `kwin` is already built
`-accessibility`, so this is not part of a screen-reader story that exists. `qtspeech` has no
`REQUIRED_USE` forcing a backend; with `-speechd` it keeps only the mock plugin.

If TTS is wanted later it should be a deliberate accessibility decision with Orca-equivalent
plumbing behind it, not a transitive dependency of a text-editing widget.

### 8. Toolchain residue the guarantee misses — −66 MiB installed, −31 MiB in the EROFS

plan/06's assertion block is about binaries; it does not look at libraries, and four gaps have
opened up behind it. All four are build artifacts in an image that states it has no toolchain.

| Residue | MiB | Why it survived |
|---|---|---|
| `/usr/lib/gcc/x86_64-pc-linux-gnu/15/32/` | 31.0 | the `*.a` sweep is `-maxdepth 1` on `$GCC_LIBDIR`; the multilib subdir is one level deeper |
| `/usr/lib/*.{a,so*,o}` (32-bit glibc) | 11.7 | the sweep only covers `/usr/lib64` |
| `/usr/lib/llvm/22/lib64/*.a` | 11.5 | section 3a removes `include`/`share`/`bin`/`cmake`, not the static archives |
| 64-bit sanitizer/fortran runtimes | 8.6 | `libgfortran`, `libasan`, `libtsan`, `libhwasan`, `liblsan`, `libubsan`, `libquadmath`, `libitm`, `libcc1`, `libgomp-plugin-nvptx` |
| `/usr/lib64/glibc-2.43/libm-2.43.a` | 2.9 | nested one level below the `-maxdepth 1` sweep |

**The 32-bit half has no users at all.** A `scanelf` pass over `/usr/lib64`, `/usr/bin` and
`/usr/sbin` finds zero `ELFCLASS32` objects, so the 42.7 MiB of 32-bit glibc and gcc runtime is
loadable by nothing in the image. (32-bit Flatpaks carry their own `Compat.i386` runtime and never
look at the host's.) Either build it away — `sys-libs/glibc -multilib`, `sys-devel/gcc -multilib`,
which also saves build time — or delete it in stage 50 and assert it stays gone.

The 64-bit sanitizer and Fortran runtimes are linked by **0** objects (`libstdc++.so.6` by 1159,
`libgcc_s.so.1` by 147, `libgomp.so.1` by 3 — those stay). Keep `libatomic.so.1` as cheap
insurance; it is 34 KB.

**Implemented 2026-08-25.** The static-library sweep in section 3 now covers both libdirs at
unlimited depth; section 3b deletes the ten unlinked runtimes and `$GCC_LIBDIR/32`, and strips the
now-missing `/32` line out of `/etc/ld.so.conf.d/05gcc-*.conf`; a new section 3d removes the
32-bit glibc. Section 4 gains four assertions: no `*.a` anywhere, no `*.so*`/`*.o` at `/usr/lib`
maxdepth 1, no `/usr/lib/cpp`, and `libgomp.so.1` added to the kept-runtime list.

Two things the implementation had to get right that the finding above did not anticipate:

- **Delete by content, not by name.** `/usr/lib` holds live files at the same depth —
  `os-release` above all, which systemd reads on every boot and which `/etc/os-release` is a
  symlink to. Section 3d tests each regular file for `\x7fELF\x01` and deletes only 32-bit
  objects, which a 64-bit consumer cannot link or load by construction. That makes the deletion
  safe rather than merely well-researched, and `os-release` is asserted to survive it.
- **`/usr/lib/libc.so` is not an ELF.** It is a GNU ld script reading
  `OUTPUT_FORMAT(elf32-i386) GROUP ( /lib/libc.so.6 ... )`. Testing only the ELF class leaves it
  behind — and then the new 32-bit-residue assertion trips on this stage's own output. 3d tests
  for the `/* GNU ld script` header as well.

Deleting the 32-bit runtime orphans about twenty ABI-mate symlinks (`libm.so ->
../../lib/libm.so.6` and friends), which is why finding 9 below is implemented in the same pass.

The `-multilib` USE alternative was not taken: `sys-libs/glibc` and `sys-devel/gcc` are `@system`
packages on a multilib profile, and a mis-set flag on glibc is discovered at the far end of a
multi-hour rebuild. Deletion is exact and needs no rebuild at all.

### 9. Three dangling symlinks into the deleted `/usr/src`

```
/usr/lib/modules/6.18.43-gentoo-dist-bin/config     -> ../../../src/…/.config
/usr/lib/modules/6.18.43-gentoo-dist-bin/vmlinuz    -> ../../../src/…/arch/x86/boot/bzImage
/usr/lib/modules/6.18.43-gentoo-dist-bin/System.map -> ../../../src/…/System.map
```

Stage 50 removes the `build` and `source` symlinks before deleting `/usr/src`, but not these
three. They are free to fix and worth fixing: `kernel-install`, `dracut` and anything that reads
`/usr/lib/modules/$(uname -r)/vmlinuz` will follow a link that resolves to nothing, and a broken
`vmlinuz` link is the kind of thing that surfaces during a recovery boot rather than in stage 70.

**Implemented 2026-08-25** as section 3e, a `prune_dangling_links` helper run over
`/usr/lib/modules` (depth 2) and `/usr/lib` (depth 1) — the two directories this stage's own
deletions empty. Three constraints shaped it:

- **Not a whole-image sweep.** Several symlinks here are *supposed* to dangle at build time and
  are asserted to exist: `/etc/resolv.conf` points into `/run`, `/etc/mtab` into `/proc`. A
  blanket "delete every broken link" would break the image and the assertions with it.
- **Absolute links resolve inside `$TARGET`, not the builder.** `/usr/lib/cpp ->
  /usr/bin/x86_64-pc-linux-gnu-cpp` is dangling in the image and present in the builder; `test -e`
  would have got that exactly backwards. Both the pruner and the matching assertion do the
  `$T$target` rewrite by hand.
- **`/usr/lib/terminfo` must survive it.** It lives at exactly the depth being swept and resolves
  only because section 3's `/usr/share` deletions happen to exclude terminfo. A mutation test of
  3e against a tree without `/usr/share/terminfo` deleted it, which is a reordering away from
  being real; plan/06 lists terminfo under "deliberately KEPT", and losing it means an unusable
  console during recovery. Section 4 now asserts it.

The sweep also picks up `/usr/lib/cpp`, the last symlink in the image still spelling the name of
a compiler driver — the section-4 banned-binary sweep only looks in `/usr/bin`, `/usr/sbin`,
`/bin` and `/sbin`, so a `cpp` in `/usr/lib` was never going to trip it.

### 10. `dev-qt/qtmultimedia[-qml]` — −28.5 MiB, with a caveat

`qtmultimedia[qml]` pulls `dev-qt/qtquick3d` (18.6) + `media-libs/assimp` (9.7) +
`qtquicktimeline`, entirely for QtQuick3D's SpatialAudio module. Nothing in the image imports
`QtQuick3D` — the only QML files that reference the Qt Multimedia stack at all are two
kirigami-addons components (`SoundsPicker.qml`, `VideoMaximizeDelegate.qml`), and those import
`QtMultimedia`, which `-qml` would also remove.

So the clean USE-flag route is not free. If the 28 MiB is wanted, deleting
`/usr/lib64/qt6/qml/QtQuick3D` and `libassimp` in stage 50 targets the dead half precisely — but
that is file surgery on a package Portage still thinks is whole, which is the shape this pipeline
otherwise avoids. Low priority.

## Policy calls, not recommendations

These are large and real, but each trades away a capability the project may want. Listed with
numbers so the decision can be made with data rather than re-derived later.

**NVIDIA compute and ray tracing — 379 MiB installed, 117 MiB shipped.**
`libcuda` (87), `libnvidia-opencl` (83), `libnvidia-nvvm` (75), `libnvoptix` (47),
`nvoptix.bin` (47), `libnvidia-rtcore` (40) are 41% of the 926 MiB NVIDIA driver. `scanelf`
confirms nothing in the image links them; they exist for CUDA/OpenCL/OptiX clients, which reach
them by `dlopen`. There is no USE flag — `nvidia-drivers` installs them unconditionally — so this
would be a prune list. Removing them breaks GPU compute for native apps and for any Flatpak that
expects the host driver to be complete (Blender, DaVinci, PyTorch containers). A desktop image
that has decided it is not a compute workstation can take it; one that has not, cannot.

**nouveau GSP firmware — 148 MiB installed, 102 MiB shipped.**
`firmware/nvidia/ga102` (98) and `firmware/nvidia/tu102` (51) are nouveau's GSP blobs, separate
from the proprietary driver's own 99 MiB at `firmware/nvidia/595.91.07`. `VIDEO_CARDS` includes
`nouveau`, so this is the fallback path if the proprietary module fails to load. A middle option:
each directory carries **two** GSP versions, and dropping only the older `gsp-535.113.01.bin`
pair frees 59 MiB while leaving nouveau working.

**`INCLUDE_CJK_FONTS=0` — 294 MiB.** Already a `build.conf` switch. Noted only because it is the
second-largest font row and the audit should say what it costs.

**`/usr/share/i18n` — 17 MiB.** glibc's locale *source* definitions. `localedef` runs at build
time in stage 40 and writes `/usr/lib/locale/locale-archive`; a read-only image cannot generate
new locales at runtime. Small, slightly risky (a few tools read `charmaps/`), listed for
completeness.

## Measured: the 0.2.1 test build (2026-08-25)

Full pipeline run with findings 2, 3, 4, 8 and 9 applied, built as `0.2.1` so the 0.2.0
artefacts survive for comparison. All eight stages passed, including both QEMU smoke boots.

**Shipped artefacts:**

| Artefact | 0.2.0 | 0.2.1 | Δ |
|---|---|---|---|
| root EROFS (lz4hc,12) | 3380.9 MiB | **2844.0 MiB** | −536.9 (−15.9%) |
| root EROFS `.zst` — the A/B payload | 2519.1 MiB | **2135.6 MiB** | −383.5 (−15.2%) |
| full disk `.img.zst` | 3496.7 MiB | **2925.6 MiB** | −571.1 (−16.3%) |
| UKI | 240.7 MiB | 240.7 MiB | **0** — see below |

The EROFS prediction from the pre-build measurements was **2844 MiB**. The build produced
2844.0 MiB. That is a coincidence in its last digit, but the method behind it is not: measuring a
candidate tree by rebuilding it into a real EROFS with the build's own `mkfs.erofs` flags predicts
the shipped result closely enough to plan against.

**Installed tree**, and the per-fix numbers, read off the built target:

| Tree | 0.2.0 | 0.2.1 | predicted |
|---|---|---|---|
| `usr/lib/firmware` | 1629 | **1154** | 1154 |
| `usr/share/fonts/noto` | 445 | **110** | 110 |
| `org.freedesktop.Platform.Locale` | 824 | **209** | 209 |
| `org.mozilla.firefox.Locale` | 48 | **8** | 8 |
| `usr/lib/gcc` | 43 | **4** | — |
| `/var` (pre-prune) | 2495 | **1832** | 1840 |
| **target, post-prune** | **8362** | **6826** | — |

Every assertion passed. The new stage-50 output reads:

```
[50-prune] multilib: removed 34 32-bit objects from /usr/lib
[50-prune] removing dangling symlink: /usr/lib/modules/…/config -> ../../../src/…/.config
[50-prune] removing dangling symlink: /usr/lib/modules/…/vmlinuz -> …/arch/x86/boot/bzImage
[50-prune] removing dangling symlink: /usr/lib/modules/…/System.map -> …/System.map
[50-prune] removing dangling symlink: /usr/lib/libatomic_ops.so.1 -> …      (+17 more)
[50-prune] prune complete, all assertions passed
```

Verified in the produced image: `qcom` gone and all eight `mediatek/mt8xxx` gone while 30
`mediatek/mt79*` Wi-Fi entries and `ath10k`/`ath11k`/`ath12k`/`qca`/`rtw89` are untouched; zero
`Condensed`/`SemiBold`/`Extra` font files with `NotoSans-Regular.ttf` present;
`xa.languages=de;en;es;fr;it;ja;pt;ru;zh` in the flatpak repo config and exactly eight Locale
subpaths deployed (no `en` — English is in the runtime, as predicted); zero `*.a` files, zero
32-bit objects at `/usr/lib` maxdepth 1, no `/usr/lib/cpp`, `os-release` and `terminfo` intact,
`libstdc++`/`libgcc_s`/`libgomp` all present; zero dangling symlinks under `/usr/lib/modules`.

**The package set did not move**: 615 packages in both builds, byte-identical `packages.txt`, and
the stage-50 audit gate passed against the unmodified `expected-packages.txt`.

### The UKI did not shrink, and that is a finding

`immos_0.2.1.efi` is the same 240.7 MiB as 0.2.0, and its initrd still contains **272 MiB of
firmware — including every blob finding 2 just deleted**. The cause is stage ordering:
`40-configure.sh` runs dracut, `50-prune.sh` runs the firmware prune, and 40 comes first. So
`prune-firmware.txt` only ever reaches the root filesystem.

The consequences are worth stating plainly:

- The qcom ARM SoC firmware is **still on the ESP**, inside the UKI, on every installed machine.
- Every A/B update still downloads it: the release directory ships a 240.7 MiB `.efi` next to the
  2135.6 MiB root payload, and roughly half that `.efi` is a duplicate of firmware the root no
  longer has.
- The same applies to finding 1: compressing firmware would not shrink the UKI either, for the
  same reason — and the boot-time analysis above, which credits `compress-zstd` with an 87 ms
  faster initramfs unpack, **assumes the initrd contains the firmware**. It does. That part holds.

Two candidate fixes, neither attempted here because both need their own verification on real
hardware rather than in a virtio guest: apply `prune-firmware.txt` before dracut runs (a
`10-prune-firmware` step at the end of stage 30, with stage 50 keeping its copy as a guard), or
narrow what dracut copies with `--omit-drivers`/a hostonly-ish policy. The first is the smaller
change and removes only firmware the image has already decided it will never load.

## Status and remaining order

Findings 2, 3, 4, 8 and 9 are **implemented** (2026-08-25). The numbers in this table are the
finding numbers above — an earlier draft of this section numbered the rows by suggested order
instead, which made "4" mean two different things. EROFS columns are measured, not extrapolated:
each tree was rebuilt with the same `mkfs.erofs -zlz4hc,12` the build uses.

| # | Change | Installed | EROFS | Status |
|---|---|---|---|---|
| 2 | ARM platform firmware out of `prune-firmware.txt` | −475 | **−284** | done |
| 3 | `media-fonts/noto[-extra]` | −335 | **−222** | done |
| 4 | flatpak `xa.languages` from `LOCALES_KEEP` | −655 (`/var`) | — (disk image only) | done |
| 8 | toolchain residue: both libdirs, no `-maxdepth`, delete by ELF class, assert | −66 | **−31** | done |
| 9 | dangling symlinks in `/usr/lib/modules` and `/usr/lib` | — | — | done |
| 1 | `linux-firmware[compress-zstd,deduplicate]` | −581 more | **−135 more** | open |
| 5 | wallpaper resolution ceiling at 3840x2160 | −193 | **−192** | open |
| — | unmerge the 15 real orphans in stage 50 section 1 | −2 | ~0 | open |

**Where that leaves the image.** Confirmed by the 0.2.1 build above: the root EROFS is
**2844.0 MiB (−15.9%)**, the A/B payload **2135.6 MiB (−15.2%)** and the installed tree
**6826 MiB (−1536)**. Adding findings 1 and 5 should reach roughly 2517 MiB of EROFS (−26%) —
though note that finding 1 will not shrink the UKI either, for the stage-ordering reason above.

**None of the five changed the package set** — 615 packages before and after, byte-identical
`packages.txt`, and the stage-50 dependency-audit gate passed against an unmodified
`expected-packages.txt`. Finding 3 does change a package's *build*, so the run needed
`--clean` (stage 30's staleness guard refuses to reuse a target whose config fingerprint moved);
with the binpkg cache warm that cost one `media-fonts/noto` rebuild and 633 binary merges, about
an hour end to end.

The second group each cost a capability and should be decided individually — and each of these
*does* move `expected-packages.txt`, because each removes packages:
`kde-apps/thumbnailers[-pdf]` (−137, or −68 keeping the thumbnailer via
`ghostscript-gpl[-l10n_zh-CN,-l10n_zh-TW]`), `dev-qt/qtspeech[-speechd]` (−50),
`kde-apps/kio-extras[-samba]` (−36, and note it no longer takes perl with it).
