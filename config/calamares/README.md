# config/calamares — the graphical installer

Everything the `installer` build profile needs to turn a live Plasma session into an installer.
None of it ships in the product: [stage 40](../../scripts/stages/40-configure.sh) installs this
tree only when the profile's sets include `installer`, and asserts its absence from every other
profile. Designed in [plan/16](../../plan/16-installer.md); the accounts page that replaced the
stock `users` module is [plan/21](../../plan/21-installer-accounts-page.md), the language page
that replaced the stock `welcome` module is [plan/22](../../plan/22-installer-language-page.md), the
greeting page that took the second half of that replacement is
[plan/23](../../plan/23-installer-greeting-page.md), and the disk page that replaced the stock
`partition` module is [plan/24](../../plan/24-installer-disk-page.md). The applications page and
its job — the one pair that adds to the image rather than writing it — are
[plan/25](../../plan/25-flatpak-apps-page.md).

## Where it goes

| here | installed as | why there |
|---|---|---|
| `settings.conf.in` | `/etc/calamares/settings.conf` | the first path Calamares searches (`libcalamares/Settings.cpp`) |
| `modules/*.conf[.in]` | `/etc/calamares/modules/` | searched before `/usr/share/calamares/modules` (`modulesystem/Module.cpp`) |
| `branding/installer/*` | `/etc/calamares/branding/installer/` | takes precedence over `/usr/share` (`CalamaresApplication::initBranding`) |
| `local-modules/<name>/*` | `/usr/share/calamares/local-modules/<name>/` | a second `modules-search` entry, so "which of these did we write?" is answered by the path |
| `system/49-installer.rules.in` | `/etc/polkit-1/rules.d/49-<id>-installer.rules` | lets the live user start the installer without a password prompt |
| `system/installer-autostart.desktop.in` | `/etc/xdg/autostart/<id>-installer.desktop` | opens the installer on login |
| `system/installer-desktop.desktop.in` | `/home/<live-user>/Desktop/<id>-installer.desktop` | the installer's shortcut on the desktop — installed straight into the home, mode 0755, because the panel pins nothing ([plan/34](../../plan/34-installer-sysext.md) §10, hand-ported from `ec691b9`) |
| `system/kscreenlockerrc.in` | `/etc/xdg/kscreenlockerrc` | drops the lock screen's password prompt — the live account's password is public — and gives the greeter the wallpaper below |
| `system/lookandfeel/contents/layouts/**` | `/usr/share/plasma/look-and-feel/<id>/contents/layouts/` | the Plasma layout script that empties the task manager's pins — all of them — and points the desktop at the wallpaper below; added to the image's own Look-and-Feel package |
| `system/wallpaper/**` | `/usr/share/wallpapers/<id>/` | the medium's only wallpaper — see below |
| `branding/installer/lang/*.ts` | `/etc/calamares/branding/installer/lang/*.qm` | compiled by stage 40 with `lrelease`; Calamares loads them as its **branding** translator, which is how our own pages get translated with no mechanism of our own ([plan/22](../../plan/22-installer-language-page.md) §4) |

`branding/installer/logo.png` is **not in this directory**. It is composed at build time by
`config/branding/make-splash-assets.py --logo --lockup`, from the same slabs and the same wordmark
as the boot splash's stub bitmap, its KMS sprite tiles and the Plasma splash's preview — one
drawing for all of them, because the user sees this sidebar within a minute of watching that
splash.

What the sidebar does **not** share with the splash is the arrangement, and since
[plan/32](../../plan/32-installer-finish-and-lockup.md) §3 that is deliberate rather than
accidental: `--lockup` puts the mark beside the wordmark instead of above it, because a 224px rail
is a strip and the splash's column — drawn to a height, as `calamares-sidebar.qml` draws it —
rendered 22 pixels wide in it. The same flag applies to `slide.png` and to nothing else, which is
exactly the line `--bg` and `--ink` already draw between the installer's two artefacts and
everything that runs before a desktop exists.

**The window icon is Calamares' own**, not this logo: `branding.desc`'s `productIcon` names
`/usr/share/icons/hicolor/scalable/apps/calamares.svg` by absolute path — `app-admin/calamares`
installs it, and it is what `calamares.desktop` and our autostart copy have always resolved to.
Its one reader is `setWindowIcon()`, which takes the value through `QIcon( QString )` — the
**file** constructor — so the icon *name* `calamares` would pass Branding's own validation
(`QIcon::fromTheme()` finds it) and then produce a null icon in silence. Stage 40 checks the path
is in the target, because Branding reports a missing image at startup, on the medium.

## The panel pins nothing; the desktop carries the shortcut

Since [plan/34](../../plan/34-installer-sysext.md) §10 (hand-ported from `ec691b9` on the
unmerged `installer-desktop-shortcut` branch, which cannot be cherry-picked because its own
`plan/33-*.md` clashes with this branch's history) the task manager comes up EMPTY. A panel is
where a running session's windows go, and this session is one installer for ten minutes; a
live-medium user looks for that installer on the desktop, not in a tray of launchers. It stays
reachable three ways: the window `/etc/xdg/autostart` opens on login, the shortcut stage 40 puts
on the live user's desktop, and the application menu. Left alone the task manager pins four:
the Icons-Only Task Manager's `launchers` default (plasma-desktop, `applets/taskmanager/main.xml`)
is System Settings, Discover, Dolphin, and `preferred://browser`.

**All four would resolve on this medium now, and the panel stays empty anyway — decided, not
inherited.** When `ec691b9` was written, two of the four were dead (`kde-plasma/discover` was
`#not-live` and no browser was preinstalled), so emptying the panel cost little. Since plan/34
both resolve: Discover is back on every profile (§6) and Firefox comes with the live session's own
Flatpak store (§7, §9). The decision was re-taken on that premise and came out the same, for the
reason above: the stick exists to install, and autostart, the desktop icon and the application
menu already put the installer in front of the user. The installed desktop is unaffected; this
layout ships only on the medium, and an installed machine keeps upstream's four pins.

That does **not** make the layout script redundant even if the pins were left stock: `KService`
drops an unresolvable launcher silently rather than leaving a hole, so a deleted write would not
mean "no pins" — it would mean whichever of the four KConfigXT defaults happen to resolve, which
today is all of them. Only the layout script's explicit `writeConfig("launchers", [])` actually
empties the panel.

Changing it costs a Look-and-Feel package, and the indirection is upstream's, not ours:

1. That default is a **KConfigXT** default, so no config file overrides it. In particular
   `/etc/xdg/plasma-org.kde.plasma.desktop-appletsrc` — the trick `baloofilerc` and
   `kscreenlockerrc` use — is never read: `Plasma::Corona::config()` opens the appletsrc with
   `KConfig::SimpleConfig` (libplasma `corona.cpp`), which does not cascade.
2. What *can* set it is the **layout script** plasmashell runs the first time it starts for a
   user, and `ShellCorona::loadDefaultLayout()` takes that script from the Look-and-Feel package
   named by `kdeglobals`' `[KDE] LookAndFeelPackage`.

So `system/lookandfeel/` is one script, and stage 40 puts it **into the image's own Look-and-Feel
package** — the one [`config/plasma/lookandfeel`](../plasma/README.md) builds for the splash — for
this profile only. It is not a package of its own. It was, once, and that is what made the medium
boot to Breeze: `kdeglobals` can name exactly one package, that package is what `startplasma`
turns into `~/.config/kdedefaults/ksplashrc` before the session starts, and a package with a
layout but no `contents/splash` therefore selected a splash that did not exist. `ksplashqml` fell
back to Breeze without a word in the journal. The full mechanism is in
[`config/plasma/README.md`](../plasma/README.md#lookandfeelpackage-not-theme).

Merging them costs nothing anywhere else: the product's copy of the package has no
`contents/layouts`, so an installed machine gets Breeze's layout, and the medium gets both halves
out of the one id. Nor does either half restate Breeze — plasma-workspace's package structure
(`shell/packageplugins/lookandfeel/lookandfeel.cpp`) installs `org.kde.breeze.desktop` as the
fallback package for any id that is not Breeze's own, and `KPackage::Package::filePath()` consults
that fallback for every file the package does not ship, so the lock screen, logout dialog, colours
and style all still resolve to Breeze, unchanged.

The script itself makes two edits and writes nothing else. It calls
`loadTemplate("org.kde.plasma.desktop.defaultPanel")` so the panel stays upstream's by
reference — kickoff, pager, tray, clock, and the input-method widget it adds for the languages
that need one — and then writes an **empty** `launchers` list on the icontasks widget it finds
there. The installer is reached from the desktop shortcut, the autostarted window and the
application menu — whose entry is `app-admin/calamares`'s own `applications:calamares.desktop`,
the one in an applications directory `KService` can resolve and the one that is translated, which
matters on a medium whose first control is a language picker.

The shortcut itself, `system/installer-desktop.desktop.in`, is modelled on the autostart entry
minus every autostart key, installed by stage 40 **straight into `/home/<live-user>/Desktop`**
rather than via `/etc/skel` — `useradd -m` has already created the home by the time stage 40
runs, so a skel copy would miss the medium's only account. That is the one deliberate exception
to [`config/plasma/README.md`](../plasma/README.md)'s "no skel copy" position, which is about
Plasma *config* and the `/etc/xdg` cascade; a document on the desktop has no cascade and one
reader. And it is mode **0755**, because Plasma will not launch a `.desktop` from the desktop
without the exec bit — it stops to ask whether to mark it executable, a prompt on the one action
this medium exists for.

The second edit is the containment's wallpaper, and it is here for the *same* reason the first
one is: a KConfigXT default is not beatable from a config file, so the layout script is the only
hook. See "The one wallpaper" below.

Kickoff's *favourites* are untouched, and the application menu still lists everything installed —
minus the **Emoji Selector**, which stage 50 deletes on live media. It arrives inside
`kde-plasma/plasma-desktop`, so there is no set marker and no USE flag for it; the argument is
[section 3g](../../scripts/stages/50-prune.sh)'s, one audience further out. A tool with no
audience on this image goes, and there is nowhere on a live stick to paste an emoji into.
`media-fonts/noto-emoji` stays: that is the font that renders the glyphs Calamares' own language
picker may have to draw, and it is not the same thing as an app that inserts them.

## The one wallpaper

`system/wallpaper/` is a Plasma `Wallpaper/Images` KPackage, installed as
`/usr/share/wallpapers/<id>/` for this profile only, and it is the **only** wallpaper on the
medium. Stage 50 section 3i prunes that directory down to this one package: the 216.8 MiB
collection never arrives (`#not-live`), and Breeze's own 38.3 MiB `Next` is deleted, because
`kde-plasma/breeze` is also the widget style and the look-and-feel fallback and cannot be dropped.
0.4 MiB against 255.1 — the medium keeps a branded desktop and still gives back 254.7 MiB.

Three things about it are constraints rather than choices:

- **The descriptor's `Id` must equal the directory name.** Same rule, and the same silent failure,
  as the Look-and-Feel package: KPackage uses that comparison to decide whether the package loads
  at all. `metadata.json.in` renders it from `DISTRO_ID`, so renaming the distro moves both.
- **The image's *basename* must parse as `<width>x<height>`.** `findPreferredImageInPackage()`
  selects on it (`packagefinder.cpp`, `resSize()`) and skips every file that does not, so a
  `wallpaper.png` would leave the package valid, the entry list non-empty and the chosen image
  null. `FillMode` is left at its KConfigXT default of 2 (PreserveAspectCrop), which is what a
  2.40:1 image needs on a 16:9 or 4:3 panel.
- **It is named by absolute path, twice, in two different files.** `MediaProxy::setSource()` puts
  the stored value through `QUrl::fromUserInput()`, which turns a bare package id into an
  `http://` URL and not a wallpaper — so what is written is the package *directory*, which
  `determineProviderType()` reads as `Provider::Type::Package`. The desktop containment gets it
  from the layout script; the **lock screen does not read that** and gets it from
  `kscreenlockerrc`'s `[Greeter][Wallpaper][org.kde.image][General]`, which is a separate config
  file, a separate group and — because `Autolock` is deliberately left on — the screen most
  likely to be facing the room during an unattended install.

Stage 40 checks all three before the medium is built, and stage 50 checks that exactly one
wallpaper survived and that both files still name it. Every one of those failures is silent at
runtime: plasmashell draws an empty containment and logs nothing anyone reads.

## What is different about installing this distro

Installing is `dd`, not unpack-and-configure. There is no squashfs to rsync, no package manager
to run, no bootloader to generate and no fstab to write: the root filesystem is an EROFS image
the pipeline already built, and installing it is copying it onto a partition. So the stock
modules that survive are the ones that **ask the user something**, and the ones that touch disks
are ours.

| stock module | disposition |
|---|---|
| `locale`, `keyboard`, `summary`, `finished`, `umount` | **kept**, unmodified |
| `welcome` | **replaced** by `language` + `greeting` — the language list first and the requirements verdict second, because the stock page's order is in `WelcomePage.cpp` and no config key reaches it ([plan/22](../../plan/22-installer-language-page.md), split in [plan/23](../../plan/23-installer-greeting-page.md)). Its requirements **box** is borrowed rather than rewritten: `checker/` is vendored into the `greeting` module, because those three classes are private to the stock module and no header of theirs is installed |
| `removeuser` | **removed from the sequence entirely**, and there is no longer anything for a replacement to remove. It used to run `userdel -f -r <live>` unconditionally, which the `/etc` overlay made "just work" as a copy-up — but a stock module cannot be told to stand down, and on a disk being *kept* rather than erased `<live>` may be the only account there is ([plan/33](../../plan/33-reinstall-keeping-files.md) §7 folded the removal into `accountsetup`, erase-path only). [plan/34](../../plan/34-installer-sysext.md) §5 went further: the live account no longer reaches the root image's lower `/etc` at all, so there is nothing left on an installed disk for a removal step to find. `accountsetup`'s own `check_no_live_user()` proves that, as a post-condition that fails the install rather than a `userdel` with something to do |
| `partition` | **replaced** by `disk` + `disksetup` ([plan/24](../../plan/24-installer-disk-page.md)). It was *kept and reconfigured* for the whole of Phase A — `allowManualPartitioning: false` plus a fixed `partitionLayout` leaves a device combo box and an Erase radio button — and what that leaves on screen is a partition editor with most of its controls taken away, in upstream's words for an installer that offers manual partitioning and side-by-side installs. Replacing the page replaced the partitioner too: a Calamares view step owns its `jobs()` |
| `users` | **replaced** by `accounts` + `accountsetup` — one module where the mechanism is a choice, because upstream's could only offer domain join as an *addition* to a local account ([plan/21](../../plan/21-installer-accounts-page.md)) |
| `unpackfs`, `mount` | **replaced** by `imagedeploy` |
| `bootloader`, `grubcfg` | **replaced** by `imagebootloader` — four file copies and a three-line `loader.conf` |
| `localecfg` | **dropped** — it runs `locale-gen` in the target, and this image has none (stage 40 drives `localedef` at build time). `imageidentity` writes `/etc/locale.conf` instead |
| `fstab`, `initcpio*`, `dracut`, `initramfs`, `machineid`, `packages`, `netinstall`, `displaymanager`, `luks*` | **dropped** — each writes something that ships inside the immutable image, or that this distro does not have |

`tests/test-installer.sh` asserts that none of the dropped modules is in the sequence.

## The one idea worth understanding

`/etc` on the installed system is an overlayfs whose upper lives on `/var`
([plan/01](../../plan/01-architecture.md)). `imagedeploy` mounts the target **the way the initrd
does** — including mounting the overlay onto its own lowerdir, the same incantation as
`config/rootfs/usr/lib/dracut/modules.d/90etc-overlay/etc-overlay.sh`.

With that in place, our own `accountsetup` runs `useradd` and `chpasswd` for the created account
under the same chroot, and the writes land in the upper on `/var` because that is what the mount
does. **No patched modules anywhere in this installer.**

There used to be a `userdel` here too, and understanding why there is not one any more is worth
doing explicitly, because the overlay is *still* the mechanism that made the old design possible
at all. Before [plan/34](../../plan/34-installer-sysext.md) §5, the live user was baked into
`/etc/passwd` inside the read-only EROFS *that the installed system also uses*, so the account
could not be deleted from an installed disk — it had to be shadowed. `userdel` rewriting the
target's `/etc/passwd` was a copy-up: the upper ended up holding the file minus that user, and
the upper's copy won. The design in plan/16 §5.4 called for a custom step to do this by hand; the
overlay did it for free — and it was still the stock `removeuser` module doing the rewriting,
unconditionally, until [plan/33](../../plan/33-reinstall-keeping-files.md) §7 folded it into
`accountsetup`'s own `remove_live_user()`, erase-path only, because a disk being *kept* might
have no other account.

plan/34 §5 removed the live account from the root image's lower `/etc` entirely — it lives only
in `/var`, seeded fresh for every boot of a live-role image and excluded, by construction, from
`var-base.tar.zst` — so there is nothing left on an installed disk's lower `/etc` for a
removal step to find. `remove_live_user()` is gone; what replaced it, `check_no_live_user()`,
reads the **merged** view this job's own writes went through (both the lower and the upper's own
copy of `passwd`, belt and braces) and **fails the install** if the live user is there anyway —
a post-condition proving the upstream guarantees still hold, not a cleanup step with work to do.

## Our modules

| module | replaces | what it does |
|---|---|---|
| `imagedeploy` | `unpackfs` + `mount` | finds **this medium's own** root device (`findmnt`, cross-checked against `liveRootPartLabel` by PARTLABEL) and copies it into the `root_<version>` partition byte-for-byte **while hashing it**, checked against `manifest.json`'s `root_erofs`; mounts root/var/**the /etc overlay**/ESP and the API filesystems; on an erase, seeds `/var` from `var-base.tar.zst` and copies **this live session's own** `/var/lib/flatpak` (`cp -a`, hard links preserved); proves none of this build's own live-medium state reached the target (`check_no_live_leakage()`); sets `rootMountPoint` |
| `imagebootloader` | `bootloader` | systemd-boot (taken from the **mounted target's own** `/usr`, not the payload, not the live system's) and the UKI (a genuine payload file, unchanged by Phase D) onto the ESP, plus a best-effort `efibootmgr` entry |
| `imageidentity` | — | autologin, written only when the accounts page asked for it (the target otherwise has no autologin config to override — [plan/34](../../plan/34-installer-sysext.md) §5), subuid/subgid, the first-boot hostname stamp, `/etc/locale.conf` |
| `language` | `welcome` (the page) | the language list, and nothing else. A compiled view module from the overlay, not here; its config is `modules/language.conf.in`, whose `languages:` list stage 40 renders from `config/languages.conf` |
| `greeting` | `welcome` (the greeting **and** the checker) | the product, the sentence about erasing the disk, and the requirements verdict — in the language the page before it chose. A compiled view module from the overlay, not here; its config is `modules/greeting.conf.in`, which carries the `requirements:` block. Not called `welcome`: a viewmodule of that name would collide with `app-admin/calamares`' own, and `ModuleManager` resolves a duplicate name by search order without saying so |
| `accounts` | `users` (the page) | the mode choice and its fields — a compiled view module from the overlay, not here; its config is `modules/accounts.conf.in` |
| `accountsetup` | `users` (the jobs) + `managedenroll` + `removeuser` | the local administrator, `/etc/hostname` and `/etc/hosts`, then the domain join or the enrolment transplant, and last a post-condition — `check_no_live_user()` — that **fails the install** if the live user reached the target's `/etc/passwd`, lower or upper ([plan/34](../../plan/34-installer-sysext.md) §5) |
| `disk` | `partition` (the page) | the machine's disks, the ones that cannot be used and why, a to-scale picture of what is about to happen, and the checkbox that has to be ticked before Next lights up. A compiled view module from the overlay, not here; its config is `modules/disk.conf.in` |
| `disksetup` | `partition` (the jobs) | releases the target's mounts, wipes it, writes the GPT and makes the two filesystems there are to make. The layout comes from `scripts/lib/layout.sh` — **the pipeline's own**, installed on the medium as `/usr/libexec/<id>-disk-layout` — so an installed machine and an image `dd`'d to a disk are partitioned by one description rather than two |
| `apps` | — (nothing stock asks this) | which extra applications to add from Flathub: the typical set, nothing, or a chosen list. A compiled view module from the overlay, not here; its config is `modules/apps.conf` (not a template — the list is facts about Flathub, not about this build). Offline it forces its own second answer, "nothing extra", and the install is none the worse for it |
| `appsetup` | — | the `apps` page's decision, downloaded: installs the published refs in the chroot and then updates every flatpak in the target, so the payload's build-time pins (`apps.lock`) are lifted to what Flathub has today. Re-checks the network itself; offline it does nothing at all, and no failure in it may fail an install |

All but `accounts`, `disk` and `apps` are Python job modules — a directory, a `module.desc` and a `main.py`.
`module.desc`'s `name` **must** equal the directory name: `ModuleManager` compares the two and silently skips the
module when they differ, which produces an install that runs to "finished" having never written
the bootloader. Both stage 40 and `tests/test-installer.sh` assert it.

## What the stick installs from

Since [plan/34](../../plan/34-installer-sysext.md) §7 (the sysext redesign, "Phase D") the root
filesystem is **not a staged file any more**. It is *this medium's own* `root_<version>`
partition — the same EROFS this live session is itself running from, built once by stage 60 and
never copied a second time onto the stick. `imagedeploy` finds it with `findmnt -no SOURCE /`
(not `/usr`: `systemd-sysext` overlays `/usr` only, so `/` is still whatever device the medium's
own UKI cmdline named), cross-checks that device's PARTLABEL against `liveRootPartLabel` before
trusting it, and then copies it into the target's `root_<version>` partition **while hashing it**
— one read of the medium, not a staged copy followed by a separate verify pass.

What's left in `/var/lib/<id>-install/` is smaller for exactly that reason:

```
uki.efi           the desktop profile's UKI, copied onto the target ESP — unchanged by Phase D
var-base.tar.zst  the desktop profile's /var, minus lib/flatpak: overlay skeleton, homes,
                  lib/immos/flatpak-preinstall.done
manifest.json     root_erofs's source ("partition", not a file), size and sha256 — checked
                  against what was just copied — plus uki.efi's and var-base.tar.zst's own
                  sizes and sha256s
```

`imagebootloader` copies `uki.efi` onto the target's ESP exactly as before Phase D, but it now
reads `systemd-bootx64.efi` — the *other* file it installs — from the **mounted target's own**
`/usr` (the disk `imagedeploy` just wrote), not from a payload file, so the two files on the ESP
come from two different places on purpose. See its own module row below.

The Flatpak store is not staged at all. `var-base.tar.zst` excludes `lib/flatpak` on purpose:
Phase D moved the store to being unpacked into **the medium's own** `/var/lib/flatpak` at *build*
time ([plan/34](../../plan/34-installer-sysext.md) §7.1), so by the time somebody clicks Install
it is an ordinary part of this live session — installable apps from Discover during the session
land in the very same directory. An erase-mode install copies that directory into the target with
`cp -a` (hard links preserved — Flatpak's OSTree-backed store depends on them for
deduplication), so **whatever was in the store at the moment Install was clicked ships on the
disk**, including anything added live. That is a feature, not a staging shortcut
([plan/34](../../plan/34-installer-sysext.md) §9): the alternative would be reading the same
Flatpak state off the disk this installer is already running from a second time.

Two artefacts moved off `/var` and off the payload directory entirely and onto the medium's own
`/usr`: the extension `lib/extensions/immos-installer` that `systemd-sysext` merges over the live
session's `/usr` (nothing merges it on an installed system — there is no persistent counterpart)
and the desktop/live `/etc` difference `tree-delta.py` computed at build time, now living in the
medium's own `/etc` overlay upper rather than duplicated under a payload path.

`imagedeploy`'s own `check_no_live_leakage()` is the post-install proof that none of this build's
own live-session state — the sysext, the live user's home, the live user's entry in the target's
`/etc` overlay upper — reached the installed disk, checked directly against what is actually on
the target after the copy rather than trusted from `var-base.tar.zst`'s own construction.

`INSTALLER_PAYLOAD_FLATPAKS=0` in `config/build.conf` still drops the Flatpak store from the
image `stage 60` builds this medium's own `/var/lib/flatpak` from — a smaller stick, and an
installed system with no preinstalled apps until someone installs them.

## Reinstalling and keeping files

Every install described above is a whole-disk erase. [plan/33](../../plan/33-reinstall-keeping-files.md)
adds the one case a machine already running this distro needs: reinstalling it — a boot that no
longer comes up, an update that went badly, a medium newer than anything `systemd-sysupdate`
reached — without losing the accounts, files, Flatpak apps and `/etc` changes already on it. All
of that lives on one partition, `var` ([plan/01](../../plan/01-architecture.md)), so keeping it
and replacing the rest is exactly what `systemd-sysupdate` already does on every update: a new
root image, a fresh boot entry, the same `/var`.

**How it's decided.** `disk-layout inspect` — a new subcommand of the same `scripts/lib/layout.sh`
that writes every partition table this pipeline produces — reads an `sfdisk --dump` of a disk on
stdin and says whether it already holds an install of this distro and, if so, whether *this
build* can keep it: the ESP and both root slots on the disk have to be at least this build's own
geometry. The disk page runs it once per eligible disk to draw the checkbox and name the disk by
product and version instead of its raw partition labels; `disksetup` runs it again before writing
anything, because a job that erases a disk does not take a page's word for one it is about to
overwrite.

**What keeping actually does.** `disksetup`'s keep path never calls `write_table()` and never
`wipefs`es the whole device: it relabels the spare slot `_empty`, then the slot the new root goes
into, `e2fsck`s and reads back the var filesystem to confirm it really is this distro's, and
`mkfs.vfat`s only the ESP. The GPT itself and `/var`'s filesystem are never touched. `imagedeploy`
skips seeding `/var` from the payload's template and the early `/etc/hostname` write;
`localesetup`, `keyboardsetup`, `imageidentity` and `accountsetup` all stand down entirely,
because the kept system's own `/etc` already has all of it. `imageidentity`'s stand-down is not a
nicety: its machine-id guard would otherwise truncate a non-empty `/etc/machine-id` on the
assumption that a non-empty one only ever got there by mistake — true on an erase, false on a
kept disk that has booted before.

**What the user sees.** The disk page's panel gains a "Keep my files, apps and settings"
checkbox, ticked by default, in the slot the encryption row occupies on every other disk — the
row that cannot apply to a partition being kept as it is. The accounts, language, location and
keyboard pages all say the kept system keeps its own answers; the summary and finished pages name
the disk being *reinstalled* rather than erased.

## Known limits (Phase A)

- ~~**Locales.**~~ **Closed by [plan/22](../../plan/22-installer-language-page.md) §2.** This used
  to read: the image compiles only what `LOCALE_GEN` names (by default `en_US.UTF-8`), so choosing
  German mostly worked while the numbers and dates stayed American. Both halves now come out of one
  table — `config/languages.conf` — so every language the picker offers has a compiled locale and a
  message catalogue, and `imageidentity`'s `target_has_locale()` guard has nothing left to refuse.
  The cost was measured rather than estimated: the locale archive goes from 2.9 MiB to 9.8 MiB.
  What remains is the *reverse* limit, and it is now the interesting one — a language absent from
  that table cannot be chosen at all, which is a deliberate trade and not an oversight.
- ~~**The medium is excluded from the disk picker by Calamares, not by us.**~~ **Ours since
  [plan/24](../../plan/24-installer-disk-page.md).** This used to read: `PartUtils::getDevices(WritableOnly)`
  drops any device holding a partition mounted at `/` (`core/DeviceList.cpp:178`), so the USB
  device disappears before the page is drawn. We no longer run that code. The rule is implemented
  three times now — in the page (`liveMediumDisk()`), in the job that writes the GPT
  (`check_target()`, which does not take the page's word for it), and in the greeting page's
  requirement checker, which already had its own copy. All three test the same thing the same way:
  a partition of disk *D* is a directory **inside** `/sys/block/D`, which is what makes
  `nvme0n1p3` resolve to `nvme0n1` without any rule about trailing digits. It remains the one
  failure in this installer that destroys data, and it is still worth verifying on the first
  hardware run — what changed is that the medium is now *visible* in the list, greyed, saying why.
- ~~**Remove the medium before rebooting, because the labels clash.**~~ **The clash is fixed by
  [plan/33](../../plan/33-reinstall-keeping-files.md) §2.** This used to read: the installed root
  and var carry the same PARTLABELs as the stick's, because those strings are the system's
  identity and are deliberately not profile-suffixed, so with both attached
  `/dev/disk/by-partlabel/` resolved each name to whichever udev saw first. It mattered more than
  a curiosity once keep mode existed to make the two-disks case routine — booting the installer
  on a machine that already runs this distro *is* keep mode's whole scenario — so a live medium's
  own image now carries `live_esp`/`live_root_<v>`/`live_var` instead, names an installed disk
  never carries. A medium built before this document still clashes; only one built after it boots
  unambiguously next to an installed disk.

  **The reminder stays anyway**, for a different reason: firmware can still boot the stick again
  regardless of what its partitions are named, if its own NVRAM entry sits ahead of the disk's or
  is the default. The `finished` page still says to remove the medium and leaves the reboot box
  unticked — that has nothing to do with PARTLABELs and everything to do with which device the
  firmware tries first.

## The accounts page, and the three things it owns

The one question anybody using this installer has to answer, and the only one where the answer
cannot be changed afterwards without reinstalling: **local accounts only**, **managed system**, or
**join an enterprise domain**. It asks it across two screens — the choice, then that choice's
fields — driven by the window's own Back and Next, because Calamares calls `ViewStep::back()`
instead of leaving a module while `isAtBeginning()` is false and `next()` instead of advancing
while `isAtEnd()` is false. One view step, one sidebar entry, two screens. It is a compiled view
module in
[`config/portage/overlay`](../portage/overlay/README.md) rather than a file in this directory,
because Calamares accepts only C++ `QtPlugin` views (`ModuleFactory.cpp:53`); what lives here is
its configuration, `modules/accounts.conf.in`, and the job it hands its answer to.

The full design is [plan/21](../../plan/21-installer-accounts-page.md). Three things about it
belong here, next to the configuration:

- **The mode is a choice, and upstream's could not be.** Stock `users` offered domain join as a
  checkbox whose `ActiveDirectoryJob` was appended *and then* `SetupGroupsJob`, `CreateUserJob`
  and `SetPasswordJob` still ran (`Config.cpp:1088-1104`). Domain was an addition, never an
  alternative — and managed enrolment was a second page with a second checkbox asking about the
  same decision. All three mechanisms are mutually exclusive in fact: `<id>-managed` refuses to
  enrol a domain-joined machine and `<id>-domain` carries the mirror check
  ([plan/19](../../plan/19-managed-mode.md) §8.7).

- **Managed mode blocks Next, and it is the only thing in this installer that does.** Everything
  else here obeys plan/18 §7.4: a service that is unreachable while somebody installs a machine
  is a Tuesday, and the install must finish anyway. That rule assumed a local account existed
  regardless — and managed mode creates none, so an install that reached `finished` with a failed
  enrolment would be a disk with nothing to log into. The page therefore runs the real enrolment
  when its button is pressed, into a scratch root on the live medium, *before* the disk is
  touched; a failure there costs nothing and can be retried or abandoned. Domain mode keeps the
  old rule exactly, because its local administrator is created either way.

- **`/usr/bin/realm` is gone, and stage 40 asserts its absence.** It existed for one caller:
  Calamares' `ActiveDirectoryJob` hardcodes the command name `realm`, and realmd is not in the
  Gentoo tree at all — while `/usr/bin/<id>-domain` is already exactly what realmd is a d-bus
  wrapper around, `adcli` plus sssd configuration ([plan/18](../../plan/18-active-directory.md)
  §4). With the stock users module out of the sequence there is nothing left to answer to that
  name, and a file called `realm` that is not realmd is worse than no file: `accountsetup` calls
  `<id>-domain join --root <target> --password-stdin` directly, on the host, and inherits the
  shim's exit-code mapping (2 unreachable, 3 credentials rejected, 4 clock skew) and its
  `domain-pending.json` writer verbatim. `tests/test-domain.sh` drives the job where it used to
  drive the shim.

Two properties of the old shim survive the move because they were never about `realm`:

- **The join runs on the HOST, not in the chroot**, with `--root` naming the mounted target. Every
  write goes through `--root`, and the medium itself is never enrolled in anything. Same for the
  managed apply.
- **A failed join never fails the install.** `<id>-domain join` preflights through `verify` before
  it writes anything; `accountsetup` records what was asked for where `<id>-domain status` will
  report it and returns `None`. Stopping instead would leave a fully deployed disk with no chosen
  account, the live user still in `/etc/passwd` and autologin still on — the outcome plan/18 §7.4
  exists to prevent.

`imagedeploy` has one job that belongs to this feature too: it writes `/etc/hostname` from global
storage as soon as the /etc overlay is mounted, *before* the join, so the computer account is not
created in AD under the live medium's own hostname — silently, and permanently. `accountsetup`
writes it again, along with `/etc/hosts`, so the hostname does not depend on which module ran
first.
