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
| `system/kscreenlockerrc.in` | `/etc/xdg/kscreenlockerrc` | drops the lock screen's password prompt — the live account's password is public |
| `system/kdeglobals.in` | `/etc/xdg/kdeglobals` | selects the Look-and-Feel package below; one key, and KConfig cascades it under `~/.config` |
| `system/lookandfeel/**` | `/usr/share/plasma/look-and-feel/<id>-installer/` | carries the Plasma layout script that pins Calamares — and nothing else — to the task manager |

`branding/installer/logo.png` is **not in this directory**. It is composed at build time by
`config/branding/make-splash-assets.py --logo`, from the same `build_block()` that produces the
boot splash's stub bitmap, its KMS sprite tiles and the Plasma splash's preview — one layout
function for all of them, because the user sees this sidebar within a minute of watching that
splash.

## The panel pins one application

The medium exists to run one program, so its task manager pins one program. Left alone it pins
four, none of them that one: the Icons-Only Task Manager's `launchers` default (plasma-desktop,
`applets/taskmanager/main.xml`) is System Settings, **Discover** — an app store on a read-only
stick that is discarded in twenty minutes — Dolphin, and `preferred://browser`, which on this
profile resolves to nothing at all because `FLATPAK_PREINSTALL=""` and Firefox travels in the
payload instead.

Changing it costs a Look-and-Feel package, and the indirection is upstream's, not ours:

1. That default is a **KConfigXT** default, so no config file overrides it. In particular
   `/etc/xdg/plasma-org.kde.plasma.desktop-appletsrc` — the trick `baloofilerc` and
   `kscreenlockerrc` use — is never read: `Plasma::Corona::config()` opens the appletsrc with
   `KConfig::SimpleConfig` (libplasma `corona.cpp`), which does not cascade.
2. What *can* set it is the **layout script** plasmashell runs the first time it starts for a
   user, and `ShellCorona::loadDefaultLayout()` takes that script from the Look-and-Feel package
   named by `kdeglobals`' `[KDE] LookAndFeelPackage`.

So `system/lookandfeel/` is a Look-and-Feel package containing a `metadata.json` and one script.
It is *not* a theme, and it does not restate Breeze: plasma-workspace's package structure
(`shell/packageplugins/lookandfeel/lookandfeel.cpp`) installs `org.kde.breeze.desktop` as the
fallback package for any id that is not Breeze's own, and `KPackage::Package::filePath()` consults
that fallback for every file the package does not ship — so the lock screen, logout dialog,
colours and style all still resolve to Breeze, unchanged.

The one exception is the **splash**, and it does not come from the fallback either. `ksplashqml`
reads `ksplashrc`'s `[KSplash] Theme` *before* it looks at `LookAndFeelPackage`, and
[`config/plasma/ksplashrc`](../plasma/README.md) sets it on every profile with a desktop — so the
live medium gets the distro's own splash ([plan/17](../../plan/17-animated-splash.md)) **and** the
task-manager layout below, out of two small packages instead of one that would have to carry both.

The script itself changes one line. It calls `loadTemplate("org.kde.plasma.desktop.defaultPanel")`
so the panel stays upstream's by reference — kickoff, pager, tray, clock, and the input-method
widget it adds for the languages that need one — and then writes `launchers` on the icontasks
widget it finds there. The pin is `applications:calamares.desktop`, `app-admin/calamares`'s own
menu entry rather than our `/etc/xdg/autostart` copy: only the former is in an applications
directory where `KService` can resolve it, and only the former is translated, which matters on a
medium whose first control is a language picker.

Kickoff's *favourites* are untouched, and the application menu still lists everything installed.

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
