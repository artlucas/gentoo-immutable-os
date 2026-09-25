# 20 — Slimming the installer medium

> **Superseded by [plan/34 §6](34-installer-sysext.md).** This document's whole premise — that
> the installer profile should be smaller than the desktop's, and that slimming it means removing
> things from it — is reversed there. plan/34 makes the medium's own root partition *the desktop
> root EROFS, byte for byte*: not the installer profile's own build at all. Every `#not-live`
> marker and USE-flag drop this document made is undone by plan/34 §6, because a systemd system
> extension can only ever *add* to the tree it is diffed against — it cannot represent "this file
> used to be here and now it's gone" — and turning any of this document's subtractions back on
> would fail that build. The one exception is §2.3 (GRUB): it stays gone,
> because it was never a subtraction from the desktop tree to begin with — GRUB is an
> unconditional dependency of Calamares alone, a file-only deletion (stage 50 §3j) of files that
> exist nowhere in the desktop tree for the diff to complain about. §2.1 (wallpapers), §2.2
> (the managed surfaces), §2.4 (ghostscript) and §2.5 (Spectacle/OpenCV) are all reversed; the live
> medium is now *closer* to the desktop than "trimmed" ever suggested it should be. What follows
> is kept for the numbers and the reasoning — several of its measurement techniques (per-tree
> EROFS rebuilds rather than the
> image-wide compression average) are reused verbatim in plan/34 — but no removal described below
> ships any more. The stick is slimmed today by carrying the product *once*, not by trimming a
> second copy of it.

The live medium is not a product. It boots once, runs Calamares, writes the desktop profile's
artifacts to a disk, and is thrown away. plan/16 established the profile that makes that
affordable — Calamares' ~25-package dependency tail is acceptable *on the stick* and would be
indefensible on every installed machine — and then trimmed exactly two things: the preinstalled
Flatpaks (~2.7 GiB, which travel in the payload instead) and podman/distrobox (61 MiB).

This document is the second pass, and it starts from a different question. Not "what does the
installed system not need?" but **"what does a medium that boots once not need?"** — which is a
much larger set, because it includes every feature whose value accrues over months of ownership.

Everything below is measured against the real `0.3.0-installer` root filesystem, extracted from
`out/immos_0.3.0-installer.root.erofs` with `fsck.erofs --extract`. EROFS columns were produced
by rebuilding each candidate tree with the build's own `mkfs.erofs -z lz4hc,12`, the way plan/10
§"Status" did, rather than extrapolated from the image-wide compression rate. That rate is
56.32%, and extrapolating from it is not a small error: the candidate trees measured here keep
between 46% (speech-dispatcher) and 100% (wallpapers) of their size, so the average would have
under-counted the biggest saving in this document by 44 percentage points.

## 1. The numbers

Where this landed, before the detail:

```
                       BEFORE      AFTER      delta
root EROFS            2904.4     2359.6     −544.8 MiB   −18.8%
installed              5064       4527       −537   MiB   −10.6%
.img.zst              5145.5     4769.4     −376.1 MiB    −7.3%
.img                 12290      12290            0        geometry, see §3
root-slot headroom    3239.6     3784.4      +544.8 MiB
```

The BEFORE column is the shipped `0.3.0-installer` build; the AFTER column is the build that
closed this document, measured the same way. Everything in §1's table and §2's per-tree figures
is a BEFORE number.

Where the installed bytes are:

| tree | MiB | note |
|---|---|---|
| `usr/lib/firmware` | 963 | unknown hardware — a live medium needs *more* of this, not less |
| `usr/lib/modules` | 593 | same |
| `usr/share/fonts` | 512 | of which noto-cjk 295, deliberately kept (see §5) |
| **`usr/share/wallpapers`** | **255** | **all but 0.4 MiB removed by this change** |
| `usr/lib/llvm` | 155 | mesa's LLVM — the session's only GPU path |
| `usr/share/icons` | 154 | breeze-icons; this is the installer's own UI |
| `usr/lib64/qt6` | 136 | ditto |
| `usr/share/locale` | 92 | ~80 languages, and the welcome page is a language picker |
| `usr/share/nvidia` + `lib64/va` + `lib64/nvidia` | 100 | unknown hardware |
| **`usr/share/ghostscript` + arphic/urw fonts** | **96** | **one Dolphin thumbnailer — removed by this change** |
| **`usr/lib/grub` + `usr/share/grub` + `grub-*`** | **68** | **never executed — removed by this change** |
| `usr/lib64/perl5` | 43 | RDEPEND of samba, rsync and sudo; not removable |

The rows are trees, not packages, and two of them overlap on purpose: the 96 MiB ghostscript row
includes the 87 MiB of `arphicfonts` + `urw-fonts` already counted inside `usr/share/fonts`. They
are listed twice because the *reason* is what makes them removable, and the reason lives with
ghostscript rather than with fonts. Do not add the column up.

## 2. What this change does

Seven removals, and they need three different mechanisms — which is the part worth carrying
forward, because "take X off the medium" has three different answers depending on how X got
there:

| | how it arrives | how it goes |
|---|---|---|
| the wallpaper collection, Spectacle, the managed KCM, Discover | named in `@desktop` | `#not-live` marker in the set — never emerged, gone from the lock and the audit |
| ghostscript and its fonts | a USE flag on a package that stays | `-pdf` in `package.use/profile.installer`, the profile-scoped fragment |
| GRUB, Breeze's `Next` wallpaper, the Emoji Selector | files inside a package that has to stay | no lever exists — stage 50 deletes the files |
| the managed-mode QML front end | files this repo's own overlay ships, on every profile | no set can name it — stage 40 removes it just after installing it |

The first is much the best of the three, and the ordering is not aesthetic. A set marker removes
the atom from `installer.lock` and `expected-packages.installer.txt`, so the audit records what
the image actually is. A file deletion leaves the package in both, and the only thing standing
between it and a silent return is a path that still matches — which is why every one of them
below is paired with an assertion that fails the build when it stops matching.

The wallpapers need two of the three rows at once, and that is not an accident of packaging: the
collection is a bare set member and goes cleanly, while the default wallpaper lives inside
`kde-plasma/breeze` alongside the widget style and the look-and-feel fallback.

### 2.1 Wallpapers — −254.7 MiB installed, −254.4 MiB EROFS

> **Revised after the fact.** This section originally removed *all* 255.1 MiB and switched the
> containment to the solid-colour plugin. The medium now keeps **one** wallpaper — 0.4 MiB of
> this distro's own artwork, `config/calamares/system/wallpaper` — so the saving is 254.7 rather
> than 255.1 MiB, and the mechanism changed from "delete the directory" to "delete around one
> package". The rest of the section is unchanged and still explains why the 255 MiB goes; the
> revision is at the end, under "the one that stays".

The most expensive tree in the image *per byte downloaded*. It is PNG and JPEG, so EROFS gives
back 0.5% of it — the installed cost and the shipped cost are the same number, which is true of
almost nothing else here:

| | installed | EROFS (`lz4hc,12`) |
|---|---|---|
| `/usr/share/wallpapers` | 255.1 MiB | **254.8 MiB** |

It comes from two packages and is therefore removed in two different ways, which is the part
worth remembering:

- **216.8 MiB, 36 wallpapers, `kde-plasma/plasma-workspace-wallpapers`.** Dropped from the SET,
  not deleted from the tree — `#not-live` in `config/portage/sets/desktop`. It is a bare set
  member whose only reverse dependency in the whole pinned tree is `kde-plasma/plasma-meta`,
  which this image has never installed, so dropping the line drops the package. That is strictly
  better than a file deletion: the atom also leaves `installer.lock` and
  `expected-packages.installer.txt`, so the audit records the truth rather than recording a
  package whose files something else quietly removed.
- **38.3 MiB, `Next`, from `kde-plasma/breeze`.** This one *has* to be a file deletion (stage 50
  section 3i). breeze is also the widget style, the colour scheme, the window decoration and the
  look-and-feel package everything else falls back to; there is no USE flag for the wallpaper and
  no dropping the package.

`Next` is also the **default** wallpaper — `org.kde.breeze.desktop/contents/defaults` says
`[Wallpaper] Image=Next` — so deleting it without doing anything else produces an empty desktop
rather than a plain one. Every arm of the fallback lands there:
`DefaultWallpaper::defaultWallpaperPackage()` reads the look-and-feel `defaults`, then the Plasma
theme's `defaultWallpaperTheme()`, then `wallpapers/Next` again. So *something* has to be named.

The product image is untouched. `desktop.lock` still carries the package, the desktop's
`/usr/share/wallpapers` is not touched by section 3i, and stage 50 asserts *that* direction too:
a `PROFILE_ROLE != live` image that has lost `Next` fails the build.

**The one that stays.** The first answer to "what does it draw, then?" was `org.kde.color`, whose
KConfigXT default is `#1d99f3` — a flat Breeze-blue desktop, no file needed, the full 255.1 MiB
saved. The medium now carries **one** wallpaper instead: `config/calamares/system/wallpaper`, a
`Wallpaper/Images` KPackage installed by stage 40 as `/usr/share/wallpapers/<id>/`, holding the
same mark the boot splash and the Calamares sidebar already show. It costs 0.4 MiB, which is
**0.15%** of what the collection cost, and it buys back the one thing the flat colour did not
have: a medium that looks like this distro rather than like an unconfigured Plasma.

That changed section 3i's *shape*, and the new shape is the part worth carrying forward. It is no
longer `rm -rf /usr/share/wallpapers`; it is

```sh
find "$T/usr/share/wallpapers" -mindepth 1 -maxdepth 1 ! -name "$DISTRO_ID" -exec rm -rf -- {} +
```

— a deletion defined by what **survives**. The alternative, naming `Next` and the collection
explicitly, keeps a wallpaper that arrives later (breeze picking up a second one, some dependency
shipping artwork) silently and for free. A saving should not depend on a comment staying current.

Two files name the package, in two different configs, because Plasma reads them from two
different places and neither falls back to the other:

| what | where | why not the other one |
|---|---|---|
| the desktop containment | the layout script, `writeConfig('Image', …)` under `['Wallpaper', 'org.kde.image', 'General']` | a KConfigXT default cannot be beaten by a config file — the same reason the panel pins need a layout script at all |
| the lock screen | `kscreenlockerrc`'s `[Greeter][Wallpaper][org.kde.image][General]` | `greeterapp.cpp` builds its own group from `KScreenSaverSettingsBase`; it never reads the containment's |

The lock screen is not a nicety here. `Autolock` is deliberately left on (see
`config/calamares/system/kscreenlockerrc.in`), so the shield engages five minutes into an install
the user walked away from — which makes it the screen most likely to be facing the room.

And the value is an **absolute path to the directory**, not the package id, in both files:
`MediaProxy::setSource()` runs it through `QUrl::fromUserInput()`, which turns a bare `immos` into
an `http://` URL and not into a wallpaper. A directory is what the wallpaper KCM itself stores,
and `determineProviderType()` reads `Provider::Type::Package` straight off it being one.

### 2.2 The managed-mode settings surfaces — ~65 KiB, and not about size

`<id>-base/<id>-kcm-managed` is `#not-live` for a reason that has nothing to do with bytes: a
live session is never enrolled. Managed mode (plan/19) is about a machine an organisation keeps
and keeps talking to, and the KCM is the surface for the person sitting at that machine. On a
stick that is discarded twenty minutes later it answers a question nobody can ask.

**Not the whole of managed mode.** `<id>-base/<id>-calamares-accounts` — the enrolment page — is
installer-only and stays exactly where it is. It is how the machine *being installed* gets
enrolled, which is the one managed-mode job a live medium genuinely has. The split is the point:
the two halves live in different sets precisely so they can differ.

**And the KCM was only half of the surface.** Marking the package `#not-live` took it out of
`installer.lock` and out of the audit, and a live medium still showed **Managed Settings** in
Kickoff under System — because the *other* front end is not a package at all. `<id>-managed-ui`
(plan/19 §7.2) is three files in `config/rootfs`:

```
usr/bin/<id>-managed-ui                          the wrapper
usr/share/<id>/managed-ui/main.qml               the app
usr/share/applications/<id>-managed-ui.desktop   Name=Managed Settings, Categories=Settings;System;
```

`install_rootfs_overlay` walks the whole of `config/rootfs`, so all three land on every profile
unconditionally — 13.6 KiB of them, measured on the 0.3.0 installer target. No set marker can
reach them and neither the lock nor the package audit can see them, which is exactly why this
went unnoticed: every artifact that records what the image
contains agreed the module was gone, and the launcher disagreed.

So it takes the fourth mechanism in the table above, and it is not a new one — `/etc/distrobox`
has used the same shape since plan/13: install the overlay, then remove what this profile must
not have. Stage 40 does it immediately after `install_rootfs_overlay`, and both stage 40 and
stage 50 then assert the *absence*, because a rename in `config/rootfs` would leave the removal
silently matching nothing and put the entry straight back.

**What stays, on purpose.** `/usr/bin/<id>-managed` — the CLI — is what the Calamares identity
module execs from the live session with `--root` pointed at a root that is not `/`, so it is half
of how the installed machine gets enrolled. [plan/21](21-installer-accounts-page.md) gave it two
callers rather than one and made the argument stronger: the `accounts` **page** runs `enroll`
against a scratch root under `/run` before the disk is written, and the `accountsetup` **job**
then runs `apply --root` against the mounted target. The polkit action stays with it: it
authorises `pkexec <id>-managed`, which is still on the medium. The line is between *the front
end a person opens* and *the tool the installer drives*, not between "managed mode" and "not".

### 2.3 GRUB — −68.4 MiB installed, **−41.6 MiB EROFS**

Not one byte of it is ever executed, and the repo had already written down why —
`config/calamares/modules/imagebootloader.conf.in`:

> `sys-boot/grub` is on this medium only because it is an unconditional RDEPEND of
> `app-admin/calamares`, and it is never run.

Confirmed in both directions it could be wrong. The **medium** boots a UKI through systemd-boot,
which stage 60 writes to the ESP from the builder. The **install** goes through our own
`imagebootloader` module — `settings.conf.in`'s `exec:` sequence never names the stock
`bootloader` or `grubcfg` — and that module reads `systemd-bootx64.efi` out of the mounted
target's own `/usr`, i.e. out of the payload, not out of this medium.

There is no USE flag and no dropping the package, so it is a file deletion (stage 50 section 3j):
`/usr/lib/grub`, `/usr/share/grub`, the 27 `grub-*` tools and the `/etc` snippets. It breaks down
as `x86_64-efi` 24.6 MiB, `i386-pc` 16.3 (a legacy-BIOS platform, on a distro that boots UEFI
only), `usr/share/grub` 12.4 and 15.1 MiB of binaries.

**The measurement was wrong the first time and the correction is instructive.** This tree was
first reported at 83.5 MiB, because `find` was pointed at `/usr/bin/grub*` *and* `/usr/sbin/grub*`
and this image has `/usr/sbin -> bin`. Every tool was counted twice. The deletion targets
`/usr/bin` only, for the same reason.

Not deleted: `app-admin/os-prober`, whose only caller is the `/etc/grub.d/30_os-prober` snippet
that goes with GRUB, and ostree's `grub2-15_ostree`. Both measure 0.0 MiB — deleting a package's
contents for no bytes buys nothing except another path that can silently stop matching.

### 2.4 Ghostscript and the fonts behind it — −96.0 MiB installed, **−70.9 MiB EROFS**

Six packages, and the chain is worth reading because only its last link is obvious:

```
kde-apps/dolphin
  -> kde-apps/thumbnailers[pdf]
       -> media-gfx/kio-ps-thumbnailer   RDEPEND: app-text/ghostscript-gpl, app-text/dvipsk
            -> app-text/ghostscript-gpl  RDEPEND: >=media-fonts/urw-fonts-2.4.9      (18 MiB)
                              l10n_zh-CN? / l10n_zh-TW? ( media-fonts/arphicfonts )  (69 MiB)
            -> app-text/dvipsk -> dev-libs/kpathsea
```

All of it serves one file: `thumbcreator/gsthumbnail.so`, the Dolphin preview for PDF and
PostScript. The 69 MiB of Chinese fonts are not there to render PDFs at all — they are
ghostscript's `l10n_zh-CN`/`l10n_zh-TW` RDEPEND, which is on because `LOCALES_KEEP` names those
two locales.

This is plan/10 finding 6 (−137 MiB at package level), applied to the medium only. On the product
it stays a judgement call about whether PDF thumbnails are worth their tail; on a stick that boots
once to run Calamares, nobody browses a PDF library.

It is a **USE change, not a set marker**, so it lives in `config/portage/package.use/
profile.installer` — the profile-scoped fragment stage 20 copies for one profile only. And unlike
the `qttools[linguist]` flag already in that file, this one removes packages, so it moves
`installer.lock` and the audit list.

`app-text/poppler-data` (12.3 MiB) **does** go with it, and this document said the opposite until
the resolver was asked. `app-text/poppler` names the atom too, so a grep finds two consumers — but
poppler's is `cjk? ( app-text/poppler-data )` and `cjk` is not in its default IUSE, while
ghostscript's is unconditional. Reading a dependency without reading the condition it sits under
is what made it look load-bearing. Nothing is lost by its going: poppler is built `-cjk` and has
never read those tables. poppler itself stays, for `kde-frameworks/kfilemetadata`.

### 2.5 Spectacle and OpenCV — −45.0 MiB installed, **−22.3 MiB EROFS**

`kde-plasma/spectacle` is 2.8 MiB and `media-libs/opencv` is 41.5 — fifteen times the size of the
only thing that wants it, an unconditional RDEPEND used for region auto-detect on capture. A
`#not-live` marker on the Spectacle line takes three packages with it, because nothing else in the
closure reaches them: `media-libs/kquickimageeditor` is Spectacle's alone, and `opencv` is
Spectacle's and kquickimageeditor's alone.

This one is a real loss rather than a free win, and it is the reason the marker is on Spectacle
and not on Dolphin or KDE Partition Manager next to it. Someone whose install just failed is the
person most likely to want a screenshot of the error, and plan/16's standing rule is that a failed
install needs a usable session. What tips it: they cannot easily get a PNG off a medium that is
about to be unplugged, and a phone photograph of an error dialog is what people actually do. The
product keeps Spectacle — on a machine somebody owns, screenshots have somewhere to go.

### 2.6 The mechanism: `#not-live`

`filter_set_file` already stripped `#cjk` / `#printing` / `#distrobox` lines when a build.conf
switch said so. `#not-live` is a fourth marker with a different kind of predicate: it is driven
by the profile's own `PROFILE_ROLE`, and it means *"this atom is for a system somebody keeps"*.

Role rather than `BUILD_PROFILE`, deliberately. A second live profile — a rescue medium, say —
should get the same answer without editing the set file, and `PROFILE_ROLE` is already the
predicate stage 40 uses to mask sysupdate and stage 80 uses to refuse a release.

That made the role a **closure input**, so it joins the keys every lock header records and stage
20 asserts against. Flipping `installer.conf`'s `PROFILE_ROLE` would otherwise silently reuse a
lock resolved under the other answer, and every atom in it would still be perfectly installable.

### 2.7 How to actually remove a package, which is not what it looks like

This is the operational half, and it is the part most worth carrying forward. **A set-level or
USE-level removal cannot be picked up by a relock**, and the second-obvious answer is worse than
the first.

The evidence, before the argument: dropping **two** named packages and one USE flag removed
**nineteen**. Nine were named or directly named; ten were orphans, and the list is not one anybody
would have produced by reading ebuilds:

```
named            spectacle, kio-ps-thumbnailer, ghostscript-gpl, dvipsk,
                 arphicfonts, urw-fonts, kquickimageeditor, opencv, kpathsea
found by the     poppler-data 12.3   protobuf 11.2   qtimageformats 2.6   abseil-cpp 2.3
resolver         libmng 0.4   jbig2dec 0.2   libidn 0.2   flatbuffers 0.6   eigen ~0
                 virtual/jpeg
```

Those ten are 29.8 MiB that a hand-edited lock would have kept, silently, while passing every
check in the pipeline.

`relock.sh` ends by writing `vdb_atoms $TARGET`, and stage 30 emerges `@locked-image`. So a
package already installed in the target stays in the lock no matter what the set now says —
including under `--all`, which re-resolves but never unmerges. Every relock mode is a
*version*-moving tool; none of them is a *membership*-changing one.

The tempting fix is to delete the atoms from the lock by hand and let stage 30's bidirectional
`lock_diff` prove it. That works for the named atoms and **silently fails for their tails**.
Dropping `kde-plasma/spectacle` also orphans `media-libs/kquickimageeditor` and
`media-libs/opencv`; dropping `thumbnailers[pdf]` orphans five more. A hand-edited lock still
names those orphans, stage 30 emerges the lock, the VDB then matches it exactly — and the build
passes while shipping every package the change was supposed to remove. Deriving the orphan set by
hand is exactly the job the resolver exists to do, and getting it wrong is invisible.

The route that works is the documented bootstrap path, used deliberately:

```sh
mv config/portage/lock/installer.lock /tmp/           # so stage 30 resolves instead of obeying
docker volume ... rm -rf /work/target-installer       # --changed-use never removes packages
scripts/build.sh --profile installer --only 20        # warns: no lock, stage 30 will make one
scripts/build.sh --profile installer --only 30        # resolves the SETS, writes the lock, dies
# review out/reports-installer/installer.lock.generated against the old one, then commit it
```

Stage 30 dies at the end with "no lock yet: review the generated one" — after the emerge and
after writing the file, so the target is fully populated and the lock is the resolver's own
answer including every orphan. What must then be reviewed is not the removals, which are known,
but the **version pins on everything else**: an unlocked resolve is free to move them, and the
whole point of plan/15 is that they do not move by accident.

## 3. Where the saving actually lands

Not in the size of the `.img`. The medium's geometry is fixed:

```
ESP 1024 + root slot 6144 + var 5120 = 12290 MiB
```

so the raw image is the same size whatever is in it. What moves is **`.img.zst`** — the artifact
anyone actually downloads — and root-slot headroom. Measured on the closing build: `.img.zst`
**5145.5 → 4769.4 MiB (−376.1)**, headroom **3239.6 → 3784.4 MiB**, and the `.img` itself
unchanged at 12290 MiB, exactly as the geometry says it must be.

The obvious follow-on is to shrink `ROOT_SLOT_SIZE_MIB` for this profile, and it does not work:
the same key is substituted into `config/calamares/modules/disk.conf.in` and
`modules/disksetup.conf.in` (it was `modules/partition.conf.in` until
[plan/24](24-installer-disk-page.md)), so it sizes the A/B slots created **on the installed
machine** as well as the medium's own. Reducing it
for the medium would reduce every installed system's slots with it. Breaking that coupling —
a separate `MEDIUM_ROOT_SLOT_SIZE_MIB`, or letting the partition module read the payload's own
size — is a prerequisite for turning any of this into a smaller stick, and it is a real change,
not a knob.

## 4. What else is on the medium that a one-time boot does not need

What is left after §2, in descending order of measured EROFS saving. §4.1 is a decision that has
been taken (to keep it); the rest are open.

### 4.1 speech-dispatcher + espeak-ng — 47.0 MiB installed, **21.9 MiB EROFS** — DECIDED, KEPT

plan/10's `dev-qt/qtspeech[-speechd]` (−50 MiB), from the other side — and the one candidate on
this list that was measured, considered and **deliberately kept**.

This is the image's only accessibility affordance, and an *installer* is the one context where a
user who needs a screen reader has no alternative: they cannot install one afterwards on a machine
they have not installed yet. Calamares has no screen-reader integration today, so nothing
currently *uses* it — but "nothing uses it yet" is a much weaker argument on a medium than it is
on a desktop, because on the desktop the user can fix it and here they cannot.

Recorded as a decision rather than an oversight so that a later size pass does not quietly take
it. If it is ever revisited, revisit the reason, not the 21.9 MiB.

### 4.2 `@domain` on the medium — ~7 MiB isolable

The live session never joins an Active Directory domain; the join happens on the installed system,
and no Calamares module does it. `PROFILE_SETS` for the installer could drop `domain` outright.

The saving is small and worth stating precisely, because the obvious estimate is wrong: sssd is
6.6 MiB and adcli 0.4, but the 22.6 MiB of samba libraries and the 43.4 MiB of perl behind them do
**not** go with it — `net-fs/samba` is also `kde-apps/kio-extras[samba]`'s dependency, and perl is
an RDEPEND of samba, rsync *and* sudo. Roughly 7 MiB for a `PROFILE_SETS` change that makes the
medium differ from the payload in one more way. Probably not worth it.

### 4.3 `kde-plasma/discover` — ~3.3 MiB plus its tail — **DONE**

An app store on a read-only stick that is discarded in twenty minutes. The medium's own layout
script already refused to pin it (`org.kde.plasma.desktop-layout.js` called it out by name), which
was the argument for removing it made in a comment instead of in a set. It is now a `#not-live`
one-liner in `config/portage/sets/desktop`.

The argument that closed it is not the 3.3 MiB — §4.2 was rejected at 7 — it is that **nothing
Discover does on this medium can outlive the session.** The root is EROFS and read-only, and what
Calamares writes to the target is the *payload's* `var.tar.zst`, not the live session's `/var`
(plan/16 §5.1). So a Flatpak installed from the live Discover is discarded at reboot, twice over.
There is no version of "the user installs something here" that ends with the software on their
machine.

Two things worth recording about the shape of it:

- **The layout script is not made redundant by the removal**, and reading it that way is the
  mistake available here. `KService` drops an unresolvable launcher *silently*, so a medium with
  the stock KConfigXT default and Discover uninstalled comes up with a two-icon panel — System
  Settings and Dolphin — and still no installer. The package marker changes what is on the stick;
  only the script changes what is on the panel.
- **The USE flags stay in `package.use/image`**, the shared fragment, and do not move to
  `profile.installer`. USE is resolved per package for the profile that still *has* the package;
  moving them would be a statement about the installer that is the opposite of what is meant.

**The tail, measured.** Two packages, not eight: `kde-plasma/discover-6.6.6` and
`kde-frameworks/purpose-6.27.0`, the latter orphaned because Discover was its only consumer here.
Everything else Discover's `COMMON_DEPEND` names — appstream, attica, knewstuff, kirigami-addons,
kstatusnotifieritem, kidletime, qcoro — stays, because something else already wanted it.
`dev-libs/appstream` is the instructive one: it reads as Discover's dependency and is
plasma-workspace's, which RDEPENDs `>=dev-libs/appstream-1[qt6]` outright whenever its own
`appstream` USE flag is on.

That is the same lesson as §2.7 from the other direction. There, two named packages took
nineteen; here, one named package takes two. **Neither number is guessable**, which is the entire
argument for deriving the orphan set with the resolver rather than by reading ebuilds.

How it was derived, since §2.7's recipe assumes a populated target and stage 50 deletes the VDB:
two `emerge --pretend` resolves of the profile's loose sets into a *pristine empty* `--root`, one
with the marker and one without, diffed against each other. The differential is what makes it
sound: the control run matched the committed lock atom-for-atom, so no version pin moved and the
two removals are the whole diff.

**Read the `to <root>/` suffix, not just the atom.** Both runs listed two packages the committed
lock does not name — `app-eselect/eselect-mpg123` and `sys-kernel/installkernel` — and the first
reading of that was "an artefact of the empty root". It is not. `emerge --root` appends
`to /work/target-installer/` to every package destined for the TARGET and prints nothing for the
ones it merges into the builder's own `/`, and those two had no suffix. They are build-root
packages, so they were never part of the `--root=$TARGET` closure the lock describes, which is
exactly why the lock does not name them. The real stage 30 settled it: `Total: 653 packages`,
`target has 651 packages`, lock verify passed. An atom list scraped from `-p` output without that
suffix conflates two roots — the same two-root distinction stage 30's `--with-bdeps=n` exists to
maintain.

### 4.3b The Emoji Selector — ~0.4 MiB — **DONE**

Not a size item, and it is listed here for completeness rather than for its bytes. `plasma-emojier`
ships inside `kde-plasma/plasma-desktop`, which is the desktop itself, so there is no set marker
and no USE flag: it is a file deletion (stage 50 section 3k), the third mechanism again.

The argument is "a tool with no audience on this image" — the one stage 50's sections 3g and 3h
already make for the Qt D-Bus Viewer and Qt Linguist — moved one audience further out. A medium
whose entire session is a language picker, a disk chooser and a progress bar has **nowhere to
paste an emoji into**.

Both descriptors go, and that is the part that would be easy to get half right: the
`/usr/share/applications` entry is what Kickoff lists, and the `/usr/share/kglobalaccel` entry of
the same name is the global-shortcut registration. Deleting only the first leaves a shortcut that
fails silently instead of one that is gone.

`media-fonts/noto-emoji` is untouched and must stay. It is what *renders* emoji — including any
the installer's own ~80-language welcome page has to draw — and it is not the same thing as an app
that inserts them.

### 4.4 The one number bigger than all of these: firmware

`usr/lib/firmware` is 963 MiB installed — by far the largest tree in the image, larger than
everything in §4.1–4.5 combined. plan/10 finding 1 (`linux-firmware[compress-zstd,deduplicate]`,
−581 installed / −135 EROFS) is still open and applies to **both** profiles.

It is not an installer-slimming item and is listed here only so the ranking is honest: anyone
optimising this medium for size should do finding 1 before anything left in this section.

### 4.5 Two that look like candidates and are not

**Printing.** `INCLUDE_PRINTING=0` in `installer.conf` is an existing knob and needs no new
mechanism, so it looks free. It saves 0.8 MiB: it drops `kde-plasma/print-manager`, and
`net-print/cups` — the 7.2 MiB in that pair — stays regardless, because it is an unconditional
RDEPEND of `dev-qt/qtbase`. Not worth making the medium differ from the payload in one more way.

**File indexing.** Baloo on a read-only live root is pure cost with no payoff, but it is already
handled and not by a package: `config/rootfs/etc/xdg/baloofilerc` ships `only basic indexing=true`
on every profile, so there is no content extraction to pay for. The binaries are 1.0 MiB.

## 5. What must not be touched, and why

Each of these looks like an obvious saving and is not:

| tree | MiB | why it stays |
|---|---|---|
| `media-fonts/noto-cjk` | 295 | The welcome page's first control is a language picker across ~80 languages. Without CJK glyphs, choosing Chinese, Japanese or Korean renders the entire installer as tofu. Of every profile this is the one that most needs those fonts — `installer.conf` sets `INCLUDE_CJK_FONTS=1` explicitly and says so. |
| `usr/lib/firmware`, `usr/lib/modules` | 1556 | A live medium boots on hardware nobody chose. It needs more coverage than the product, not less. (Compressing it — §4.4 — is a different question from dropping any of it.) |
| `usr/lib/llvm`, `usr/share/nvidia`, `lib64/va` | 255 | mesa's LLVM backend and the GPU userspace. Same argument. |
| `usr/share/icons`, `usr/share/locale`, `lib64/qt6` | 382 | This *is* the installer's user interface. |
| `net-print/cups` | 7.2 | An unconditional RDEPEND of `dev-qt/qtbase`. Not removable, only rebuildable. |
| `kde-apps/kio-extras` | — | An unconditional RDEPEND of `plasma-workspace`. |
| `kde-apps/dolphin`, `sys-block/partitionmanager` | — | Kept by decision (plan/16): someone whose install just failed wants a file manager and a disk tool more than any other session does. Note that §2.5 removes Spectacle from beside them — the line is that a file manager and a partitioner are how you *recover* a failed install, and a screenshot tool is how you *report* one, which is worth less on a medium with nowhere to put the file. |
| `dev-qt/qtspeech[speechd]` | 47 | See §4.1. Measured, considered, kept. |
| `/var` (3874 MiB staged) | — | The payload. It *is* the product. |

## 6. Status

| # | change | installed | EROFS | status |
|---|---|---|---|---|
| 2.1 | wallpapers off live media, less the one that stays | −254.7 | **−254.4** | done |
| 2.2 | managed KCM off live media | −0.06 | ~0 | done |
| 2.2 | managed QML front end off live media | −0.01 | ~0 | done |
| 2.3 | GRUB, never executed | −68.4 | **−41.6** | done |
| 2.4 | ghostscript + arphic/urw fonts | −96.0 | **−70.9** | done |
| 2.5 | Spectacle + kquickimageeditor + OpenCV | −45.0 | **−22.3** | done |
| 4.1 | speech-dispatcher + espeak-ng | −47.0 | −21.9 | **kept, deliberately — accessibility** |
| 4.2 | `@domain` off the medium | −7 | ~−3 | open, probably not worth it |
| 4.3 | Discover off live media | −3.3 + purpose | see below | done — 2 packages, resolver-derived |
| 4.3b | the Emoji Selector off live media | −0.4 | see below | done — audience, not bytes |
| 4.4 | firmware compression (plan/10 §1) | −581 | **−135** | open, both profiles |
| 4.5 | printing, file indexing | −1.8 | ~−1 | rejected — measured, and the saving is not there |

The 2.1, 4.3 and 4.3b rows postdate the build measured in the paragraph below, so that paragraph
describes the image *before* them. They were built and measured together on 2026-09-09, and
because they move in opposite directions their EROFS columns are only meaningful combined:

```
                     closing build   + 2.1/4.3/4.3b      delta
root EROFS                  2359.6           2357.0      −2.6 MiB
.img.zst                    4769.4           4767.1      −2.3 MiB
.img                       12290            12290         0        geometry, §3
```

−2.6 MiB net is three removals against one addition: Discover, `kde-frameworks/purpose` and the
Emoji Selector come off, and 0.36 MiB of wallpaper goes back on — and that 0.36 does not compress,
because it is a PNG, which is the same property that made §2.1 worth 254 MiB in the first place.

At the package level: `installer.lock` 653 atoms → 651, `expected-packages.installer.txt` 640
names → 638, and stage 50's audit gate matched the emerged set on the first run.

**Measured, not predicted.** The build that closed this document put the installer root EROFS at
**2359.6 MiB, down from 2904.4 — −544.8 MiB, −18.8%** — with 653 packages against 672, zero prune
violations, and no version pin moved.

That beat the prediction, which was ~2515 MiB, by 156 MiB, and the reason is worth recording
because it will recur: every per-tree figure in §2 was measured by PATH (`/usr/share/ghostscript`,
`libopencv*`, `/usr/lib/grub`), and a package is not a path. Each one also owns libraries,
binaries and data outside the directory it is named after, and on top of that came the ten-package
orphan tail in §2.7 that no path-based estimate could have included. Path-measured trees are a
**lower bound** on what removing the package frees; treat them that way when ranking the items
still open in §4.

What is left is one big number and some small ones. §4.4 (firmware compression, −135 MiB EROFS,
both profiles) is worth more than everything still open here combined. §4.2 and §4.3 together are
under 5 MiB and each makes the medium differ from the payload in one more way, which is a cost
this document has otherwise been careful to charge for.
