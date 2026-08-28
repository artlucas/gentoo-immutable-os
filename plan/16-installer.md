# 16 — Graphical Installer (Calamares) & Build Profiles

The installer that [plan/08](08-roadmap.md) reserved as roadmap item 1, decided and designed.
Two things arrive together, and the second is the one that makes the first possible:

1. **Calamares** as the installer, resolving plan/08's "spike Calamares against a purpose-built
   Kirigami app before committing".
2. **Build profiles** — the pipeline stops producing *the* image and starts producing a named
   one. The installer lives in a profile that is never installed, so Calamares and its
   dependency tail never reach a user's disk.

Profiles are not packaging convenience. They are the entire reason the Calamares answer is
affordable, and §2 measures why.

## The decision

**Calamares (`app-admin/calamares`), running in a live-only `installer` profile, installing a
`desktop` profile payload.** Whole-disk erase only; swap partition with hibernation; no LUKS.

The reasoning in one paragraph: the objection to Calamares was never its UI or its
architecture — it was that its dependency closure would ship on every installed system, on a
distro whose stated identity is a minimal native footprint with a hard audit gate. Once the
installer lives in a profile that is built, booted from USB, and then thrown away, that
objection evaporates entirely, and what is left is a mature installer with ~80 languages of
translations and a page flow that thousands of installs have already debugged. The cost moves
from "permanent, on every machine" to "transient, on the install medium" — which is a cost this
project is happy to pay, and one it can measure.

## 1. Installer platform survey

Asked for explicitly, and worth recording so the decision is not relitigated from memory.

| Platform | Toolkit | Verdict for this distro |
|---|---|---|
| **Calamares** | Qt6 + KF6 | **Chosen.** In the pinned tree (`app-admin/calamares`). Modular: keep the UI modules, replace the work modules. Its dependency tail is real (§2) and profiles contain it. The only mature installer that is already Qt/KDE-native |
| Purpose-built Kirigami/QML app | Qt6 + Kirigami | The runner-up, and genuinely close. Adds **zero** new runtime dependencies — `qtbase`, `qtdeclarative`, `qtsvg`, `kirigami`, `kirigami-addons`, `kpackage`, `kparts`, `polkit-qt` and `kpmcore` are all already in `image.lock`. `config/splash/splash.c` is precedent that this project ships its own compiled programs with no ebuild and no overlay. Rejected because it puts the destructive-disk UI, the ~80 translations and the whole page-flow state machine on us, to save a cost profiles already remove |
| Anaconda | Python + GTK4 (new UI: Cockpit/React) | Wrong ecosystem end to end — rpm, dnf and blivet are load-bearing inside it. Not Qt. Would import a second toolkit for one screen flow |
| Ubuntu Desktop Installer / subiquity | Flutter (Dart) + Python | Imports an entire third toolkit and a Dart runtime. Snap-oriented delivery. Ubuntu-specific assumptions throughout |
| YaST | Ruby, with a real Qt frontend | The Qt frontend is genuine, but YaST is a SUSE control-centre framework that happens to install, not an installer. Not meaningfully packaged for Gentoo |
| archinstall | Python, TUI | Not graphical. Arch-specific |
| `bootc install to-disk` | none (CLI) | Conceptually our closest cousin — install *is* writing an image, with no package transactions. But it is the CLI half only and is tied to OSTree/OCI container images. We already have this half: it is `dd`, and §5 shows the whole install is 40 lines of it |
| `calamares-gentoo-livecd` | — | In the tree, and **not** for us. It is Gentoo's own Calamares config: unpack a stage3, configure Portage, install GRUB. Every one of those steps is something this distro deliberately does not have. Named here only so nobody installs it expecting a shortcut |

There is no KDE-official installer. In practice "KDE-native installer" means Calamares or your
own Kirigami app, which is exactly the choice above.

## 2. What Calamares actually costs — measured, 2026-08-28

Resolved against the real thing: the last build's config root and target rootfs in the
`immos-work` volume, with the pinned tree, via
`emerge --config-root=… --root=/work/target --pretend --with-bdeps=n app-admin/calamares`.

**First, it does not resolve at all.** The stable version is refused:

```
!!! The ebuild selected to satisfy "app-admin/calamares" for /work/target/ has unmet requirements.
- app-admin/calamares-3.3.14-r4::gentoo … PYTHON_SINGLE_TARGET="-python3_12 -python3_13"
  The following REQUIRED_USE flag constraints are unsatisfied:
    exactly-one-of ( python_single_target_python3_12 python_single_target_python3_13 )
```

The image is on **python 3.14** (`=dev-lang/python-3.14.6_p1`, admitted deliberately — see
plan/06's "Python — RESOLVED again at the first Plasma build"). Both stable Calamares revisions
cap at `PYTHON_COMPAT=python3_{11..13}`. Only `3.3.14-r8` and `3.4.2-r1` support 3.14, and both
are `~amd64`.

> **A keyword exception is mandatory, not optional.** The alternative — adding python3_13 as a
> second `PYTHON_TARGET` — would put a second interpreter in the image and is strictly worse.

With `app-admin/calamares ~amd64`, the resolution succeeds on **`3.4.2-r1`** and the tail is:

| Package | Download | Note |
|---|---:|---|
| `dev-libs/boost-1.90.0-r2` | 166.7 MiB | `USE=python` required. Biggest single compile in the tail |
| `sys-boot/grub-2.14-r5` | 14.2 MiB | **`GRUB_PLATFORMS="efi-64 pc"`** — it builds the legacy BIOS platform too, on a UEFI-only distro |
| `sys-boot/grub-themes-gentoo-1.0-r2` | 5.1 MiB | Gentoo-branded GRUB artwork, pulled by grub's `branding` USE |
| `app-admin/calamares-3.4.2-r1` | 4.8 MiB | |
| `sys-fs/fuse-3.18.2` + `fuse-common` | 7.5 MiB | |
| `dev-cpp/yaml-cpp`, `sys-libs/cracklib`, `dev-libs/libpwquality`, `sys-apps/dmidecode`, `sys-fs/squashfs-tools`, `sys-libs/efivar`, `sys-boot/efibootmgr`, `sys-boot/os-prober`, `app-text/mandoc`, … | ~6 MiB | |
| **Total** | **25 packages, 204.4 MiB of downloads** | |

Plus three USE changes portage demands:

```
>=dev-libs/boost-1.90.0-r2 python
>=dev-libs/libpwquality-1.4.5-r3 python
>=sys-boot/grub-2.14-r5 mount          # required by os-prober
```

Download size is not installed size — boost's 166 MiB is a source tarball and the installed
libraries are a fraction of it. **The installed footprint is unmeasured until the first
`installer` profile build**, and measuring it is a Phase A exit criterion (§8).

What this table is really saying: a UKI-booting, systemd-boot, EROFS distro would ship **GRUB
with a legacy-BIOS platform, Gentoo's GRUB theme artwork, `os-prober` and `squashfs-tools`** —
none of which it can ever use — because they are unconditional `RDEPEND`s with no USE flag to
turn them off. In the product image that is indefensible. On an install medium it is a shrug.

That is the whole argument for profiles, and it is why the profile mechanism is Phase 0 rather
than a later tidy-up.

### 2.1 Trimming the tail (optional, later)

Once the profile exists, the tail can be tuned without touching the desktop profile:
`GRUB_PLATFORMS="-pc"` drops the BIOS platform, and `sys-boot/grub -branding -fonts -themes
-sdl -truetype -doc` drops the theme package. `mount` must stay (os-prober needs it). Worth
perhaps 15–20 MiB on a live image, so it is a nicety, not a blocker. Do it after the first
build has produced a real number to compare against.

## 3. Build profiles

### 3.1 What a profile is

`config/profiles/<name>.conf`, sourced after `config/build.conf`, same discipline as build.conf
(`key="value"` only, no logic, validated by `validate_config()`).

```sh
# config/profiles/installer.conf
PROFILE_DESC="Live USB/ISO installer environment"
PROFILE_ROLE="live"                   # target | live
PROFILE_SETS="base desktop hardware installer"
PROFILE_ROOT_SLOTS="1"                # live media needs no B slot
FLATPAK_PREINSTALL=""                 # the single biggest saving — see 4.1
INCLUDE_DISTROBOX="0"
VAR_SIZE_MIB="8192"                   # must hold the payload
```

Three profiles at the start:

| Profile | Role | Sets | Is |
|---|---|---|---|
| `desktop` | target | base desktop hardware | Today's image, byte-for-byte unchanged in intent. The product, and the installer's payload |
| `installer` | live | base desktop hardware **installer** | Trimmed live desktop + Calamares. Booted, never installed |
| `console` | target | base hardware | Replaces `--console-only`, the M1 image |

### 3.2 The one rule that matters

> **A profile selects package *sets*. It must not change USE flags.**

Both profiles emerge from the same config root, the same `make.conf` and the same
`package.use`, so every package they share resolves to an identical binpkg in `/cache/binpkgs`.
The `installer` root is therefore mostly a **merge**, not a compile — it recompiles only the
Calamares tail. Break this rule and the second profile becomes a second multi-hour Qt/KDE
build.

This also keeps `portage_config_hash()` identical across profiles, so the existing one-way
hash assertion in `scripts/stages/20-builder-setup.sh:66` keeps working untouched. The
installer's `package.accept_keywords` and `package.use` entries live in the shared config root
and are simply inert for a profile that never emerges those atoms.

One consequence, and it is a one-time cost: adding those entries changes
`portage_config_hash()`, which invalidates **every** existing lock. A `relock.sh --all` for
each profile is part of Phase 0.

### 3.3 Locks and the audit gate become per-profile

This is the part with teeth, and it fixes a limitation that already exists.

Today `config/portage/lock/image.lock` is singular, and stage 20 *dies* when the switches
recorded in its header disagree with the build (`20-builder-setup.sh:76-84`, checking
`INCLUDE_CJK_FONTS INCLUDE_PRINTING INCLUDE_DISTROBOX CONSOLE_ONLY`). So **you cannot currently
hold a console lock and a desktop lock at the same time** — a `--console-only` build demands a
relock, and relocking back demands another. Profiles make that untenable, so:

| Today | With profiles |
|---|---|
| `config/portage/lock/image.lock` | `config/portage/lock/<profile>.lock` |
| `config/portage/expected-packages.txt` | `config/portage/expected-packages.<profile>.txt` |
| `out/<id>-<ver>.img` | `out/<id>-<ver>-<profile>.img` (`desktop` keeps the bare name) |
| `scripts/relock.sh --all` | `scripts/relock.sh --all --profile <name>` |

The header machinery already records the reshaping switches, so this is a path variable and a
loop, not new machinery.

**The audit gate is the guarantee.** `config/portage/expected-packages.desktop.txt` will not
contain `app-admin/calamares`, `sys-boot/grub`, `sys-boot/os-prober`, `dev-libs/boost` or
`sys-fs/squashfs-tools`. Stage 50 fails the build on unexplained additions. So "Calamares does
not get into the installed system" is not a convention anyone has to remember — it is an
assertion that breaks the build, which is how every other invariant in this project is held.

### 3.4 What must *not* carry the profile name

The profile is a **build-time** concept and must not leak into the installed system's identity.
These stay exactly as they are today, or updates break:

- `PARTLABEL=root_<version>` — no profile suffix
- `EFI/Linux/<id>_<version>.efi` — no profile suffix
- `/etc/os-release`'s `IMAGE_ID` / `IMAGE_VERSION` — `sysupdate` reads these as "what is
  installed" ([plan/04](04-image-and-boot.md))
- `usr/lib/sysupdate.d/*.transfer` match patterns

A system installed from the `installer` profile's payload is indistinguishable from one dd'd
from the `desktop` image. That is the point.

One live-only exception: `systemd-sysupdate` should be **masked** in the `installer` profile.
A live medium offering to update itself is confusing at best.

### 3.5 Files that change

| File | Change |
|---|---|
| `config/profiles/*.conf` | New |
| `config/portage/sets/installer` | New — `app-admin/calamares` and nothing else (deps resolve) |
| `config/portage/package.accept_keywords/image` | `app-admin/calamares ~amd64` |
| `config/portage/package.use/image` | boost `python`, libpwquality `python`, grub `mount` |
| `scripts/build.sh` | `--profile <name>`; `--console-only` becomes an alias for `--profile console` |
| `scripts/lib/common.sh` | Load the profile; derive `LOCK_DIR` paths, `IMG_NAME`, layout from it |
| `scripts/stages/20-builder-setup.sh` | Per-profile lock path; drop the `CONSOLE_ONLY` special case |
| `scripts/stages/30-target-rootfs.sh` | Sets from `PROFILE_SETS` instead of the `CONSOLE_ONLY` branch |
| `scripts/stages/40-configure.sh` | Profile-conditional bits (autologin, splash, sysupdate mask); **remove `resume` from the dracut omit list** (§6) |
| `scripts/stages/50-prune.sh` | Per-profile `expected-packages` |
| `scripts/stages/60-image.sh` | `PROFILE_ROOT_SLOTS`; profile-suffixed output |
| `scripts/stages/65-iso.sh` | New (§7) |
| `scripts/stages/90-vendor.sh` | `FETCH_SETS` from `PROFILE_SETS` |
| `scripts/relock.sh` | `--profile` |
| `tests/` | Per-profile awareness in `test-pin-policy.sh`, `test-image-layout.sh`, `test-build-dryrun.sh` |

`CONSOLE_ONLY` currently threads through eight files as a bare boolean. Folding it into the
profile mechanism removes it, which is a net simplification even ignoring the installer.

## 4. The `installer` profile, measured

### 4.1 What actually trims — and what does not

Measured against the last build's target rootfs, 2026-08-28. **Two of my own candidates were
wrong**, and the numbers reorder the rest completely:

| Candidate | Size | Trimmable? |
|---|---:|---|
| **Preinstalled Flatpaks** (`/var`) | **~2.7 GiB** | **Yes** — `FLATPAK_PREINSTALL=""`. Dwarfs everything else combined |
| `media-fonts/noto-cjk` | 294 MiB | Yes, but **should not be** — see below |
| `podman` + `distrobox` | 61 MiB | Yes — `INCLUDE_DISTROBOX=0` |
| `net-print/cups` | 8 MiB | **No.** Unconditional `RDEPEND` of `dev-qt/qtbase`, which is built `USE=cups` |
| `kde-apps/kio-extras` | — | **No.** Unconditional `RDEPEND` of `kde-plasma/plasma-workspace` |
| `kde-plasma/discover` | 1 MiB | Yes, and not worth a line of config |
| `kde-apps/dolphin` | 1 MiB | Yes, and worth *keeping* — a failed install wants a file manager |
| `kde-plasma/print-manager` | <1 MiB | Yes, and irrelevant |

Two findings worth keeping even if the installer never ships:

- **`INCLUDE_PRINTING=0` does not remove CUPS from any image.** `dev-qt/qtbase`'s `RDEPEND`
  contains a bare, unconditional `net-print/cups`, and qtbase is built with `cups` in USE
  (the plasma desktop profile turns it on). The knob removes `kde-plasma/print-manager` and
  leaves the printing stack in place. Removing CUPS would mean `-cups` on qtbase, which changes
  qtbase's binpkg and so violates §3.2's rule outright.
- **`kio-extras` is not optional under Plasma.** `plasma-workspace` hard-depends on it.

So the trim list collapses to *one line of config that matters* — dropping the Flatpak payload
— plus `INCLUDE_DISTROBOX=0`. The rest is noise. The "trimmed live desktop" is therefore much
closer to the full desktop than it sounds, and that is fine: the live environment stays a
usable Plasma session, which is what someone whose install just failed actually needs.

### 4.2 Keep CJK fonts in the installer profile

`INCLUDE_CJK_FONTS=0` would save 294 MiB and break the thing Calamares is best at. The welcome
page's first control is a **language picker** across ~80 languages; choosing Chinese, Japanese
or Korean on an image with no CJK glyphs renders the entire installer as tofu. The `installer`
profile is the one profile that most needs those fonts. Keep them.

## 5. What "install" means here

### 5.1 It is `dd`, not unpack-and-configure

Calamares' default shape is: unpack a squashfs onto a mounted read-write target, chroot in,
configure, install a bootloader. **Almost none of that applies.** Installing this distro is
what `scripts/stages/60-image.sh` already does in about 40 lines:

1. Write a GPT to the target disk
2. Populate the ESP: systemd-boot + `loader.conf` + the UKI
3. `dd` the root EROFS into slot A and label the partition `root_<version>`
4. `mkfs.ext4` the var partition and seed it (overlay skeleton, `home/`, Flatpak store)
5. Seed identity — user, hostname, locale, timezone, keyboard
6. Disable the baked-in live autologin

Steps 1–4 use only tools already in the image: `sfdisk` (util-linux), `mkfs.ext4` (e2fsprogs),
`mkfs.vfat` (dosfstools), `mkswap`, `dd`, `bootctl`. `mkfs.erofs` is **not** needed — the root
image is copied byte-for-byte, never rebuilt.

One constraint disappears on the way. The build is loopless and mtools-based because it runs in
a container where loop devices are flaky ([plan/04](04-image-and-boot.md)). The installer runs
on real hardware with a real kernel: it can simply `mount` things. `mtools` is in `builder.lock`
and not in `image.lock`, and it does not need to be.

### 5.2 The `/etc` overlay makes stock Calamares modules work

The interesting part. `/etc` on this system is an overlayfs whose upper lives on `/var`
([plan/01](01-architecture.md)), so "configure the installed system" means writing into
`/var/overlay/etc/upper` — which sounds like it breaks every chroot-shaped installer module
ever written. It does not, if the installer mounts the target the way the initrd does:

```sh
mount -o ro  "$ROOT_PART" /tmp/target                      # erofs
mount        "$VAR_PART"  /tmp/target/var                  # ext4
mkdir -p     /tmp/target/var/overlay/etc/{upper,work}
mount -t overlay overlay  /tmp/target/etc \
      -o lowerdir=/tmp/target/etc,upperdir=/tmp/target/var/overlay/etc/upper,workdir=/tmp/target/var/overlay/etc/work
mount        "$ESP_PART"  /tmp/target/efi
```

That overlay line is not invented here — it is the same incantation `90etc-overlay` already
performs in the initrd, including the mount-onto-its-own-lowerdir trick (plan/01, "/etc
overlay"). With it in place, `rootMountPoint=/tmp/target` and Calamares' stock `locale`,
`keyboard` and `users` modules write to `/etc/...` exactly as they would on a mutable distro,
and the writes land in the upper on `/var` because that is what the mount does. **No module
patching required for the identity steps.**

### 5.3 Module map

| Calamares module | Disposition |
|---|---|
| `welcome` | **Keep** — language picker + requirements (disk size, power, network) |
| `locale` | **Keep** — timezone + locale, into the overlay |
| `keyboard` | **Keep** |
| `users` | **Keep** — writes passwd/shadow/group into the overlay (see 5.4) |
| `summary`, `finished` | **Keep** |
| `shellprocess`, `contextualprocess` | **Keep** — the workhorses for every step in 5.1 |
| `umount` | **Keep** |
| `partition` | **Replace** — a small disk-select module. Whole-disk erase only, so the UI is a disk picker, not a partition editor. The layout is fixed by design and users may not choose filesystems or mountpoints |
| `mount` | **Replace** — the overlay stack in 5.2 |
| `unpackfs` | **Replace** — `dd` an EROFS; there is no squashfs and no rsync-onto-target |
| `bootloader` / `grubcfg` | **Drop** — the UKI is already built and signed-shaped; the ESP gets systemd-boot and a file copy |
| `fstab` | **Drop** — fstab ships in the image's immutable lower ([plan/04](04-image-and-boot.md)) |
| `initramfs` / `dracut` | **Drop** — the initrd is inside the UKI, built by stage 40. The target has no dracut, by design |
| `machineid` | **Drop** — systemd generates one at first boot into the overlay upper (plan/01) |
| `packages` / `netinstall` | **Drop** — there is no Portage on the target. This is the toolchain-free guarantee, not an omission |
| `removeuser` | **Replace** — see 5.4 |
| `displaymanager` | **Replace** — see 5.4 |
| `luks*` | **Drop** — no encryption in v1 |

### 5.4 Three things that need custom steps

**Removing the live user.** `LIVE_USER` is baked into the image's `/etc/passwd` and
`/etc/shadow`, which live in the read-only EROFS *that the installed system also uses*. It
cannot be deleted. It must be **shadowed**: copy `passwd`, `shadow`, `group`, `gshadow` up into
the overlay upper with the live user removed and the real user added. Overlay upper wins
file-wise (plan/01), so the upper's copy replaces the lower's entirely. Calamares' `users`
module does the adding; a `shellprocess` step before it does the copy-up and the removal.

**Disabling autologin.** `/etc/plasmalogin.conf.d/10-autologin.conf` is likewise in the
immutable lower. Deleting a lower file through an overlay needs a whiteout device; do not.
Drop-ins sort lexically, so the installer writes `20-no-autologin.conf` into the upper and the
later file wins. Clean, inspectable, and reversible by the user.

> Watch the mtime here. Plasma Login Manager only re-reads `plasmalogin.conf.d` when its newest
> mtime beats a zero-initialised stamp — the bug that cost 0.3.0 its autologin
> ([plan/04](04-image-and-boot.md) step 1). Installer-written files carry a real current mtime,
> well after the EROFS's `SOURCE_DATE_EPOCH`, so this is safe — but it is exactly the kind of
> thing that fails silently, so stage 70's install test must assert the greeter appears.

**subuid/subgid.** [plan/13](13-distrobox.md) flags this: rootless podman needs subordinate ID
ranges, stage 40 allocates them for `LIVE_USER`, and a real user created by the installer needs
its own. Calamares' `users` module does not do subuid. One more `shellprocess` step writing
`/etc/subuid` and `/etc/subgid` into the overlay.

## 6. Disk layout: swap and hibernation

### 6.1 The layout

`var` stays **last** so `repart.d/50-var.conf` can still grow it to the end of the disk:

```
p1  esp    1 GiB          PARTLABEL=esp    type=EFI System
p2  root   6 GiB          PARTLABEL=root_<version>  type=root(x86-64)
p3  root   6 GiB          PARTLABEL=_empty          type=root(x86-64)
p4  swap   >= RAM         PARTLABEL=swap   type=linux-swap
p5  var    remainder      PARTLABEL=var    type=var
```

**The factory image is unchanged.** The dd'd `.img` keeps today's tested four-partition layout;
only *installed* systems get swap. `compute_layout()` and `emit_sfdisk_script()` in
`scripts/lib/common.sh` gain a swap-aware variant rather than being rewritten.

Because the installer sizes `var` to the remainder up front, the first-boot repart grow becomes
a no-op on installed systems. It still matters for dd-to-USB, so it stays.

### 6.2 No `resume=` is needed, and that is the whole trick

plan/01 rejected a swap partition partly over "resume-offset fragility". The cmdline objection
is real — the cmdline lives *inside* the UKI, baked at build time and identical on every
machine, so a per-machine `resume=` is impossible by construction. It is also unnecessary:

- GPT type `0657fd6d-a4ab-43c4-84e5-0933c84b4f4f` makes the partition **discoverable**.
  `systemd-gpt-auto-generator` enables it as swap with no fstab entry and no cmdline token.
- `systemd-hibernate-resume-generator` plus the `HibernateLocation` EFI variable that systemd
  writes on hibernate handle resume with no cmdline token either.

The image is on **systemd 260.1** (both `image.lock` and `builder.lock`), so all of this is
well within supported territory.

### 6.3 One real code change

`scripts/stages/40-configure.sh:580` currently omits the dracut `resume` module, with a comment
citing plan/08:

```
--omit "… qemu-net resume"
#   … and resume (plan/08: zram-only swap, no hibernation, so there is no resume= to honour).
```

Resume happens in the initrd, so `resume` must come out of that omit list and the comment must
be retargeted at this document. Expect the UKI to grow slightly; measure it, because the ESP
budget and the UKI's size history are tracked carefully in
[plan/04](04-image-and-boot.md) and [plan/11](11-kernel-boot-audit.md).

### 6.4 The A/B hazard, honestly

Hibernate on version N → `sysupdate` installs N+1 → reboot resumes N's memory image under N+1's
kernel. The risk is smaller than it first looks, and it should be stated accurately rather than
darkly:

- The kernel writes its own identity into the swsusp header and **refuses to resume an image
  from a different kernel**. The failure mode is "resume declined, normal boot, session lost" —
  not memory corruption.
- `/var` is the only writable filesystem, and an update never touches it (plan/01). After a
  declined resume it is an unclean unmount, which the ext4 journal handles.

So the realistic cost is a silently lost session, which is still bad. Two mitigations, both
cheap:

1. A `/usr/lib/systemd/system-sleep/` hook that **refuses hibernation while an update is
   staged** — the ESP holding a UKI newer than the running `IMAGE_VERSION` is exactly the
   condition, and `<id>-update status` already computes it.
2. `<id>-update apply` discourages staging an update while a hibernation image exists.

### 6.5 Sizing and priority

- Swap ≥ RAM, with headroom: `min(RAM + 2 GiB, RAM * 1.5)`, floor 4 GiB. Hibernation needs the
  image to fit.
- zram keeps the higher priority; the partition is the overflow tier and the hibernation target.
- **Verify at Phase B:** hibernation with zram active needs the image to land in *disk* swap,
  not zram. This is a known-fiddly interaction and it needs a real test on real hardware, not a
  reading of the documentation.

## 7. The ISO (stage 65)

### 7.1 Do the raw image first

The installer does **not** need an ISO to work. The `installer` profile builds through stage 60
into a normal raw `.img` that dd's to a USB stick exactly like today's image, boots through the
existing UKI path, and needs **no new boot machinery at all**. The payload simply lives in the
live image's `/var`.

That is Phase A, and it delivers a fully working installer. The ISO is Phase B and buys media
convenience — optical, Ventoy, and VM "attach a CD-ROM" workflows — not capability.

### 7.2 Contents

```
/EFI/BOOT/BOOTX64.EFI              systemd-boot (removable-media path, no NVRAM)
/EFI/systemd/systemd-bootx64.efi
/loader/loader.conf
/EFI/Linux/<id>_<ver>-live.efi     the LIVE UKI (live cmdline)
/<id>/root-<ver>-installer.erofs   live root
/<id>/root-<ver>.erofs             PAYLOAD root  (desktop profile)
/<id>/<id>_<ver>.efi               PAYLOAD UKI   (copied to the target ESP)
/<id>/var-template.tar.zst         payload /var seed
/<id>/manifest.json                versions, sha256s, sizes
```

Built with `xorriso -as mkisofs … -isohybrid-gpt-basdat` and an El Torito EFI boot image
(a FAT image holding systemd-boot + the live UKI). **`dev-libs/libisoburn` is not in
`builder.lock`** and must be added — builder packages come from the binhost as binaries, so
that is cheap.

### 7.3 Live boot needs one new dracut module

The stock UKI cmdline says `root=PARTLABEL=root_<ver> rootfstype=erofs`. On an ISO there is no
such partition, so the live UKI needs its own cmdline and a `90live-root` dracut module that:

1. finds the ISO9660 filesystem by label,
2. loop-mounts `/<id>/root-<ver>-installer.erofs` at `/sysroot` read-only,
3. mounts a tmpfs at `/sysroot/var`,
4. mounts the `/etc` overlay with its upper on that tmpfs,
5. switch-roots.

Roughly 60 lines, and the house already has two hand-written dracut modules to copy the shape
from — `90etc-overlay` and `90repart-sysroot`.

### 7.4 Size, with real numbers

From the 0.3.0 build: root EROFS **2761.7 MiB**, UKI **59.8 MiB**, Flatpak payload ~2.7 GiB.

| Configuration | Estimated ISO |
|---|---:|
| Live root + payload root + payload UKI + Flatpak var-template | **~8.5 GiB** |
| Same, `FLATPAK_PREINSTALL_MODE="firstboot"` (needs network on first boot) | ~5.8 GiB |
| Shared-layer optimisation (§7.5) with Flatpaks | ~5.8 GiB |
| Shared-layer optimisation without Flatpaks | ~3.1 GiB |

8.5 GiB is a large ISO. It is also an installer that works with no network at all, on a project
whose stage 90 exists specifically so releases stay rebuildable offline. Default to the offline-
complete ISO and expose `ISO_PAYLOAD_FLATPAKS` for people who would rather download.

### 7.5 The obvious optimisation, deliberately deferred

The live root and the payload root differ **only** by the Calamares tail, and the ISO stores
both in full — about 2.7 GiB of duplication. The fix is to ship the payload EROFS once and
build the live root as an overlay of payload + a small `calamares-layer.erofs`, produced with
`rsync --compare-dest=<payload-root>` so the layer holds only the differing files.

It is elegant, it roughly halves the ISO, and it makes the live boot path materially more
complex. Not in Phase B. Revisit once the ISO exists and its real size is measured.

## 8. Phasing

**Phase 0 — Profiles.** No installer code. Introduce `config/profiles/`, make locks and
`expected-packages` per-profile, fold `--console-only` into `--profile console`, relock all
profiles. Ship `desktop` and prove it is unchanged.
*Exit:* a `desktop` build produces the same package set as today, and `console` builds without
destroying the desktop lock.

**Phase A — Installer on raw media.** Add `config/portage/sets/installer` and the `installer`
profile; build it through stage 60 to a raw `.img`. Write the Calamares branding, the custom
disk-select module, and the `shellprocess` steps for §5.1 and §5.4. No ISO, no swap.
*Exit:* dd the installer image to a USB stick, boot it on hardware, install to an internal
disk, and boot the installed system into a Plasma session as a real user with no live account
present. Plus: **the measured installed size of the Calamares tail**, which §2 could only
estimate from download sizes.

**Phase B — Swap, hibernation, ISO.** The 5-partition layout, the dracut `resume` change, the
sleep hook from §6.4, then stage 65 and `90live-root`.
*Exit:* installed system hibernates and resumes on real hardware; the ISO boots in QEMU and
from a Ventoy stick.

**Phase C — Polish.** Grub tail trimming (§2.1), the shared-layer ISO (§7.5), Secure Boot
enrolment in the installer (plan/08 roadmap 2, which the installer is the natural home for).

## 9. Testing

Stage 70 is a QEMU harness already ([plan/07](07-testing.md)). The install path extends it
rather than replacing it:

- **T-INST-1** boot the installer image in QEMU with a second blank virtual disk; drive
  Calamares headlessly (it supports a config-driven unattended path); assert the target disk's
  GPT, partition labels, EROFS magic at the slot offset (the check in `60-image.sh` is directly
  reusable), and ESP contents.
- **T-INST-2** boot the *installed* disk; assert `graphical.target`, the created user exists,
  the live user does not, autologin is off, timezone/locale/keyboard match what was requested.
- **T-INST-3** assert the installed system updates — `sysupdate` must see it as a normal
  installation (§3.4), which is the sharpest test that the profile did not leak.
- **T-INST-4** (Phase B) hibernate/resume in the guest; then the staged-update refusal.
- Offline suite: profile config lint, per-profile lock header assertions, and a test that
  `expected-packages.desktop.txt` contains none of the Calamares tail — the §3.3 guarantee,
  asserted rather than trusted.

## 10. Open questions

1. **Installed size of the Calamares tail.** §2 has download sizes only. Boost's 166 MiB
   tarball could be anywhere from 20 to 80 MiB installed. Answered by the first Phase A build.
2. **Does `app-admin/calamares-3.4.2-r1` build in the two-root emerge?** It is `~amd64` and this
   pipeline's split (BDEPEND → builder, RDEPEND → target) has surfaced RDEPEND-only-configure-dep
   failures before — `config/portage/sets/buildhost` exists solely for that class of bug, and its
   header warns the Qt6/KF6 cmake graph is where the next one will come from. Calamares is
   exactly that shape. If it bites, the fix is a `buildhost` entry, and the ebuild's
   `python_get_includedir` export in `src_prepare` is the first place to look.
3. **Hibernation with zram active** — §6.5. Needs a hardware test.
4. **Which Calamares release.** `3.4.2-r1` is newer and resolved cleanly here; `3.3.14-r8` is
   the conservative choice and also supports python 3.14. Both are `~amd64`, so there is no
   stability argument for the older one. Pin whichever survives Phase A, in
   `config/portage/lock/installer.lock` like everything else.
5. **Unattended-install config for T-INST-1.** Calamares can run non-interactively, but the
   exact shape that works headlessly in QEMU needs establishing before the test can exist.
6. **Should `console` remain a profile at all?** It exists for M1, which is long past. Keeping
   it costs a lock file; dropping it removes the only current consumer of `PROFILE_SETS`
   variation besides the installer. Decide at Phase 0, with the milestone status in hand.

## Changes to other documents

| Document | Change |
|---|---|
| [00-overview](00-overview.md) | Non-goals: "Graphical installer / installer ISO" and "Hibernation" both move out. M5 becomes concrete |
| [01-architecture](01-architecture.md) | Disk layout gains swap for installed systems; the "swap: zram only, no hibernation" line points here; "First boot & default user" points at §5.4 for how the live user actually goes away |
| [04-image-and-boot](04-image-and-boot.md) | "The future installer ISO (roadmap) automates exactly this" → §5.1 and §7 |
| [08-roadmap](08-roadmap.md) | Roadmap item 1 is decided; record the Calamares/Kirigami spike as resolved by measurement, and move Secure Boot's installer-flow option (2b) to Phase C |
| [13-distrobox](13-distrobox.md) | "The installer will need the same subuid work" → §5.4, which now specifies it |
| README | New row in the plan table |
