# config/calamares — the graphical installer

Everything the `installer` build profile needs to turn a live Plasma session into an installer.
None of it ships in the product: [stage 40](../../scripts/stages/40-configure.sh) installs this
tree only when the profile's sets include `installer`, and asserts its absence from every other
profile. Designed in [plan/16](../../plan/16-installer.md).

## Where it goes

| here | installed as | why there |
|---|---|---|
| `settings.conf.in` | `/etc/calamares/settings.conf` | the first path Calamares searches (`libcalamares/Settings.cpp`) |
| `modules/*.conf[.in]` | `/etc/calamares/modules/` | searched before `/usr/share/calamares/modules` (`modulesystem/Module.cpp`) |
| `branding/installer/*` | `/etc/calamares/branding/installer/` | takes precedence over `/usr/share` (`CalamaresApplication::initBranding`) |
| `local-modules/<name>/*` | `/usr/share/calamares/local-modules/<name>/` | a second `modules-search` entry, so "which of these did we write?" is answered by the path |
| `system/49-installer.rules.in` | `/etc/polkit-1/rules.d/49-<id>-installer.rules` | lets the live user start the installer without a password prompt |
| `system/installer-autostart.desktop.in` | `/etc/xdg/autostart/<id>-installer.desktop` | opens the installer on login |
| `system/kscreenlockerrc.in` | `/etc/xdg/kscreenlockerrc` | drops the lock screen's password prompt — the live account's password is public — and gives the greeter the wallpaper below |
| `system/lookandfeel/contents/layouts/**` | `/usr/share/plasma/look-and-feel/<id>/contents/layouts/` | the Plasma layout script that pins Calamares — and nothing else — to the task manager, and points the desktop at the wallpaper below; added to the image's own Look-and-Feel package |
| `system/wallpaper/**` | `/usr/share/wallpapers/<id>/` | the medium's only wallpaper — see below |
| `system/realm.in` | `/usr/bin/realm` (**mode 0755**) | the Active Directory front door — see below |

`branding/installer/logo.png` is **not in this directory**. It is composed at build time by
`config/branding/make-splash-assets.py --logo`, from the same `build_block()` that produces the
boot splash's stub bitmap, its KMS sprite tiles and the Plasma splash's preview — one layout
function for all of them, because the user sees this sidebar within a minute of watching that
splash.

## The panel pins one application

The medium exists to run one program, so its task manager pins one program. Left alone it pins
four, none of them that one: the Icons-Only Task Manager's `launchers` default (plasma-desktop,
`applets/taskmanager/main.xml`) is System Settings, Discover, Dolphin, and `preferred://browser`.

**Two of those four are not installed here.** `kde-plasma/discover` is `#not-live` in
`config/portage/sets/desktop` ([plan/20](../../plan/20-installer-slimming.md) §4.3) — an app
store on a read-only stick that is discarded in twenty minutes, whose every install is thrown
away on reboot because what Calamares writes to the target is the *payload's* `/var`, not this
session's. The browser is a Flatpak this profile does not preinstall: `FLATPAK_PREINSTALL=""` and
Firefox travels in the payload instead.

That does **not** make this script redundant, and the distinction is worth keeping straight:
`KService` drops an unresolvable launcher silently rather than leaving a hole, so a medium with
the stock default and neither package installed comes up with a two-icon panel — System Settings
and Dolphin — and still no installer. Removing the package changes what is on the stick; only the
layout script changes what is on the panel.

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
that need one — and then writes `launchers` on the icontasks widget it finds there. The pin is
`applications:calamares.desktop`, `app-admin/calamares`'s own menu entry rather than our
`/etc/xdg/autostart` copy: only the former is in an applications directory where `KService` can
resolve it, and only the former is translated, which matters on a medium whose first control is a
language picker.

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
| `welcome`, `locale`, `keyboard`, `users`, `summary`, `finished`, `umount` | **kept**, unmodified |
| `removeuser` | **kept** — and it works only because of the overlay; see below |
| `partition` | **kept, reconfigured into a disk picker**: `allowManualPartitioning: false` plus a fixed `partitionLayout` leaves a device combo box and an Erase radio button |
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

With that in place, Calamares' stock `locale`, `keyboard`, `users` and `removeuser` modules write
to `/etc/...` exactly as they would on a mutable distro, and the writes land in the upper on
`/var` because that is what the mount does. **No patched modules anywhere in this installer.**

It is also what makes `removeuser` work at all. The live user is baked into `/etc/passwd` inside
the read-only EROFS *that the installed system also uses*, so the account cannot be deleted — it
has to be shadowed. `userdel` rewriting a lower file **is** a copy-up: the upper ends up holding
the file minus that user, and the upper's copy wins. The design in plan/16 §5.4 called for a
custom step to do this by hand; the overlay does it for free.

## Our modules

| module | replaces | what it does |
|---|---|---|
| `imagedeploy` | `unpackfs` + `mount` | verifies the payload against `manifest.json`, writes the root EROFS into the `root_<version>` partition, mounts root/var/**the /etc overlay**/ESP and the API filesystems, unpacks the `/var` template, sets `rootMountPoint` |
| `imagebootloader` | `bootloader` | systemd-boot (taken from the **payload's** `/usr`, not the live system's) and the UKI onto the ESP, plus a best-effort `efibootmgr` entry |
| `imageidentity` | — | autologin off, subuid/subgid, the first-boot hostname stamp, `/etc/locale.conf` |

They are Python job modules — a directory, a `module.desc` and a `main.py`. `module.desc`'s
`name` **must** equal the directory name: `ModuleManager` compares the two and silently skips the
module when they differ, which produces an install that runs to "finished" having never written
the bootloader. Both stage 40 and `tests/test-installer.sh` assert it.

## The payload

The medium carries what it installs, in `/var/lib/<id>-install/`:

```
root.erofs      the desktop profile's root filesystem, written to the target byte-for-byte
uki.efi         the desktop profile's UKI, copied onto the target ESP
var.tar.zst     its /var: overlay skeleton, homes, the preinstalled Flatpak store
manifest.json   versions, sizes and sha256s — checked before anything is written
```

All four are staged by stage 40 from **another profile's** build output, unmodified. That is what
makes an installed machine indistinguishable from one `dd`'d from the desktop `.img`, which is the
property `systemd-sysupdate` depends on ([plan/16 §3.4](../../plan/16-installer.md)).

`INSTALLER_PAYLOAD_FLATPAKS=0` in `config/build.conf` drops `var.tar.zst` — a smaller stick, and
an installed system with no preinstalled apps until someone installs them.

## Known limits (Phase A)

- **Locales.** The image compiles only what `LOCALE_GEN` names (by default `en_US.UTF-8`) into a
  locale archive on the **read-only** root, and nothing on the installed system can add to it.
  `imageidentity` therefore writes `/etc/locale.conf` only for a locale the target can actually
  load, and warns otherwise — writing an uncompiled locale would silently give the user `C`.
  `LOCALES_KEEP` (translated UI) is a much longer list, which is why choosing German mostly works
  while the number and date formats stay American.
- **The medium is excluded from the disk picker by Calamares, not by us.**
  `PartUtils::getDevices(WritableOnly)` drops any device holding a partition mounted at `/`
  (`core/DeviceList.cpp:178`). The live root is mounted at `/`, so the USB device disappears
  before the page is drawn. Worth verifying on the first hardware run: it is the one failure in
  this installer that destroys data.
- **Remove the medium before rebooting.** The installed root and var carry the same PARTLABELs as
  the stick's, because those strings are the system's identity and are deliberately not
  profile-suffixed. With both attached, `/dev/disk/by-partlabel/` resolves each name to whichever
  udev saw first. The `finished` page says so, and leaves the reboot box unticked.

## `realm`, and why a file with that name is here

The users page offers domain join because `modules/users.conf.in` sets `allowActiveDirectory:
true`. Calamares' implementation of that checkbox is, in full, one command
(`src/modules/users/ActiveDirectoryJob.cpp` in 3.4.2):

```c++
Calamares::System::instance()->runCommand(
    RunLocation::RunInHost,
    { "realm", "join", m_domain, "-U", m_adminLogin, "--install=" + installPath, "--verbose" },
    QString(), m_adminPassword, std::chrono::seconds( 30 ) );
```

`realm` is realmd, which **is not in the Gentoo tree at all** — and realmd is itself only a d-bus
wrapper around `adcli` plus sssd configuration generation, which is precisely what
`/usr/bin/<id>-domain` already is ([plan/18](../../plan/18-active-directory.md) §4). So rather
than patch Calamares or write a C++ view module, `system/realm.in` answers to the name it calls
and forwards. One join implementation, two callers: this shim on the medium, and the CLI on the
installed system.

Four things about that snippet are constraints rather than trivia, and all four are in the
shim's comments:

- **`RunInHost`.** The command runs on the live medium, not in the chroot, with `--install=`
  naming the mounted target. Every write therefore has to go through `--root`, and the medium
  itself is never enrolled in anything.
- **30 seconds, hard.** The shim does no work that is not the join, and every preflight check is
  bounded with `timeout` rather than left to a DNS resolver's own patience.
- **That argv is a contract.** `tests/test-domain.sh` drives the rendered shim with those exact
  tokens, so a Calamares bump that changes them fails the offline suite instead of failing a
  stranger's install.
- **The exit code is a loaded gun.** A non-zero exit becomes `JobResult::error` and stops the
  installation — and this job runs *before* `CreateUserJob`, `removeuser` and `imageidentity`, so
  stopping there leaves a fully deployed disk with no chosen account, the live user still in
  `/etc/passwd`, and autologin still on. The shim verifies the domain first, writes nothing if
  that fails, records the attempt in the target for `<id>-domain status` to report, and **exits 0
  either way**. See [plan/18](../../plan/18-active-directory.md) §7.4.

`imagedeploy` has one job that belongs to this feature too: it writes `/etc/hostname` from global
storage as soon as the /etc overlay is mounted. `ActiveDirectoryJob` is appended *before*
`SetHostNameJob` (`Config.cpp:1088` vs `:1109`), so without that the computer account would be
created in AD under the live medium's own hostname — silently, and permanently.
