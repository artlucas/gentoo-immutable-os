# 34 — The medium is the product: Calamares as a system extension

The installer medium carries the product twice. It boots a root of its own — the `installer`
profile's EROFS, 2366 MiB in 0.3.1, slimmed by [plan/20](20-installer-slimming.md) — and it holds
a second, complete copy of the product in `/var/lib/immos-install`: the desktop root EROFS
(2777 MiB), its UKI (60 MiB) and a `var.tar.zst` whose only real content is the Flatpak store
(899 MiB). `immos-0.3.1-installer.img` is **12290 MiB raw and 4769 MiB `.zst`**. The session it
boots into is the trimmed desktop that plan/20 made: no wallpapers, no Spectacle, no Discover and
no applications, because the five Flatpaks on the stick belong to the machine being installed and
never run here.

This document removes the second copy. The medium's own root partition **is** the desktop root
EROFS, byte for byte, and installing writes that partition to the chosen disk. Calamares and its
dependency tail stop being part of any root image: they become a **systemd system extension** that
exists only on the stick's `var` partition and is merged over `/usr` at boot. An installed disk
gets a fresh `/var`, so it never sees the extension, and its root is the release artifact itself.

The second goal falls out of the first. A stick that boots the product *is* a live system: the
full desktop, the five applications, a persistent `/var` that grows to fill the stick — and an
installer on top.

## 1. What was decided before this was written

| Question | Answer |
|---|---|
| Calamares on an installed system | **Absent**, not hidden. It ships as a system extension on the stick's `var`, which an installed disk never receives (§3) |
| Where the preinstalled Flatpaks come from | **The stick.** The live session runs them, and the install copies the stick's store to the target, so an offline install still gets every app (§7.1, §9) |
| The `live` user | **Leaves the root image entirely.** It is seeded into `/var` for every image that boots as live — the stick, `desktop.img`, `console.img` — so no installed or updated root can carry it (§5) |
| One UKI or two | **Two, differing only in `.cmdline`.** The live UKI is the desktop UKI re-wrapped, and the build asserts every other section is byte-identical (§8) |
| The unmerged `installer-desktop-shortcut` branch | **Its desktop icon is ported (§10); its plan/34 is superseded.** "No Flatpak on the stick, native Firefox in `@installer`" assumed a live root separate from the product. This document removes that root |

The branch's own `plan/33-installer-desktop-shortcut.md` and `plan/34-installer-native-firefox.md`
already clash with `main`'s `plan/33-reinstall-keeping-files.md`, and now with this file. Neither
is carried over. The text that still applies — the icon and the empty task manager — is folded into
§10.

## 2. The shape

```
medium (live_* names, plan/33 §2)                      installed disk
─────────────────────────────────────────              ─────────────────────────────────
live_esp    systemd-boot + LIVE UKI                    esp        systemd-boot + desktop UKI
live_root_V desktop root EROFS, byte for byte ──copy─▶ root_V     the same bytes
live_var    lib/extensions/immos-installer/            _empty
              usr/…  Calamares, its tail, our pages    var        var-base + the copied Flatpaks
            overlay/etc/upper/
              passwd shadow group gshadow subuid subgid   (the live user)
              plasmalogin.conf.d/10-autologin.conf
              calamares/  polkit-1/rules.d/49-immos-installer.rules
              xdg/autostart/immos-installer.desktop  xdg/kscreenlockerrc  xdg/kdeglobals
              ld.so.cache  systemd/system/systemd-sysupdate.{service,timer} → /dev/null
            lib/flatpak/           the five apps: the live session's, and the install's source
            lib/immos-install/     manifest.json  uki.efi  var-base.tar.zst
            home/live/             Desktop/immos-installer.desktop
```

One rule produces all of it:

> **Everything that makes the stick "live" lives on its `/var`. The root image is always the plain
> product.**

The `/etc` overlay ([plan/01](01-architecture.md)) already puts every change to `/etc` in an upper
directory on `var`. The stick just ships with an upper that is not empty. `/usr` gains the same
property through `systemd-sysext`, which systemd provides for exactly this purpose.

## 3. Why a system extension

`systemd-sysext` merges extension trees found in `/etc/extensions`, `/run/extensions` and
**`/var/lib/extensions`** over `/usr` and `/opt` as a read-only overlayfs. Checked against the
pinned systemd 260.1 and the last desktop build:

- **It is already on.** `/usr/lib/systemd/system-preset/90-systemd.preset:35` is
  `enable systemd-sysext.service`, and `/work/target` carries the
  `sysinit.target.wants/systemd-sysext.service` symlink. The unit is
  `ConditionDirectoryNotEmpty=|/var/lib/extensions`, so on every installed machine it is a no-op.
  The product image needs no change to gain this.
- **It runs early enough.** The unit is `After=local-fs.target` and
  `Before=sysinit.target systemd-tmpfiles-setup.service`, and the manual guarantees it has
  finished before `basic.target`. `/var` is mounted in the initrd (`x-initrd.mount`). So
  dbus, polkitd and the display manager all start against the merged `/usr`.
- **A plain directory is a valid extension.** No loop device, no image policy, no verity — a
  directory on the `var` ext4 is enough. The builder's loopless constraint
  ([plan/04](04-image-and-boot.md)) never comes into it.
- **It is bound to one release.** The extension must carry
  `usr/lib/extension-release.d/extension-release.<name>` whose `ID=` matches the host's and whose
  `VERSION_ID=` matches unless `SYSEXT_LEVEL=` is set. The host's `os-release` says
  `ID=immos` and `VERSION_ID=0.3.1`. An extension built for another version refuses to merge.
- **Its limits fit the Calamares tail.** It cannot carry `/etc` or `/var`, and the manual says it
  is "not suitable for shipping system services or systemd-sysusers definitions". The tail has
  neither. Its `/etc` files go to the overlay upper instead (§7.2).

Alternatives considered:

| | Why not |
|---|---|
| One image carrying Calamares, with Calamares hidden after install | The installed root would differ from the release root of the same version. Calamares, boost, cracklib and our pages would sit on every machine until the first update, and on its rollback slot for one more. It is hidden, not absent, and the plan/16 §3.3 audit guarantee becomes a convention |
| plan/16 §7.5's shared-layer root: payload EROFS + `calamares-layer.erofs` overlaid in the initrd | Same outcome, but it needs a new dracut module to assemble `/sysroot`. `systemd-repart` would then find no single device behind `/sysroot/usr`, which is the failure [plan/12](12-first-boot-reboot-loop.md) spent a document on. `systemd-sysext` does the same overlay after boot, with code that already exists |
| `systemd-confext` for the live `/etc` | It mounts a read-only overlay over `/etc`. The live session writes `/etc` (NetworkManager connections, machine-id), and `/etc` already has a writable overlay whose upper can simply be pre-filled |

## 4. Phase A — the root image stops naming partitions

The desktop EROFS now boots in two places. Its `/etc/fstab` says `PARTLABEL=var` and `PARTLABEL=esp`,
and on the stick those are the wrong names: `live_var` is the stick's. With an installed disk
attached they are worse than wrong — they resolve to the installed disk, which is the two-disk bug
[plan/33 §2](33-reinstall-keeping-files.md) fixed. So the labels leave the root image and move to
the one place that already differs per role, the UKI command line.

systemd-fstab-generator takes fstab lines on the command line as
`systemd.mount-extra=WHAT:WHERE[:FSTYPE[:OPTIONS]]` (systemd 254+). In the initrd, an entry whose
options include `x-initrd.mount` is mounted under `/sysroot`
(`src/fstab-generator/fstab-generator.c:1400-1419`, `mount_in_initrd()` at 317). It is honoured in
the booted system too. `passno` defaults to "is a device path", so `/var` is still fsck'd.

| File | Change |
|---|---|
| `config/rootfs/etc/fstab.in` | The `/var` and `/efi` lines and the `@IMG_*_PARTLABEL@` tokens go; `tmpfs /tmp` stays. The header says where the mounts went. The file is the same for every profile, so it can stop being a template |
| `scripts/stages/40-configure.sh`, `CMDLINE` (1945–1951) | Adds `systemd.mount-extra=PARTLABEL=$IMG_VAR_PARTLABEL:/var:ext4:defaults,x-initrd.mount,x-systemd.growfs,x-systemd.after=systemd-repart.service` and `systemd.mount-extra=PARTLABEL=$IMG_ESP_PARTLABEL:/efi:vfat:umask=0077,noauto,x-systemd.automount` |
| stage 40 verify (1988–2001) | Now asserts that the fstab names **no** `PARTLABEL`, and that the cmdline carries both mount-extras with this role's names |
| `scripts/stages/60-image.sh` (267–271) | The dump-versus-names check is unchanged. It is still the image's partitions that carry the names |

**`x-systemd.after=systemd-repart.service` is new, and it is the part to watch.** An fstab entry is
read by `initrd-parse-etc.service`, after `initrd-root-fs.target`, and so after the
[90repart-sysroot](../config/rootfs/usr/lib/dracut/modules.d/90repart-sysroot/module-setup.sh)
repart has grown the partition. A command-line entry is known from the generator's first run, and
nothing orders it after repart. Without the option, growfs can grow the filesystem to the *old*
partition size, and `/var` only reaches the end of the disk on the second boot. Stage 70's "var grew"
assertion is what proves the option works.

This is a product change. A new release's UKI and root arrive together through sysupdate and each
UKI boots only its own root, so a new UKI never meets an old fstab or the reverse.

## 5. Phase B — the live user leaves the root image

`live` (uid 1000, `wheel,video,pipewire`, password `live`) and its autologin drop-in are baked into
the lower `/etc` of every root image today (`40-configure.sh:274-331`,
`config/rootfs/etc/plasmalogin.conf.d/10-autologin.conf.in`). The installer removes them from what
it installs: `accountsetup`'s `remove_live_user()` runs `userdel -f -r live` on the erase path and
only warns if that fails, and `imageidentity` writes `20-autologin.conf` to cancel the drop-in. A
failed `userdel` therefore leaves a wheel account with a published password on an installed
machine, and every sysupdate'd root keeps the account in its lower.

It moves to `/var`, where the rule in §2 says it belongs:

- **Stage 40** snapshots `/etc/{passwd,shadow,group,gshadow,subuid,subgid}` and creates the user
  exactly as today. It then moves the six modified files to `$TARGET/var/overlay/etc/upper/` and
  restores the snapshots. The lower is left pristine, and the upper holds the whole of each file
  (overlayfs replaces a file wholesale).
- **`10-autologin.conf.in` moves out of `config/rootfs`** to a live seed that stage 40 renders into
  the upper, so `install_rootfs_overlay` stops putting it in the lower. Its header's warning still
  applies: PLM parses the directory only when its newest mtime is non-zero, so stage 60 asserts
  that of the file in the upper.
- **`/home/live` stays in `$TARGET/var`**, so `desktop.img` and `console.img` still come up logged
  in. Stage 70's `autologin=yes` check (`70-test.sh:94-106`) is unchanged and now tests this
  mechanism.
- **Stage 60's var template excludes the live bits** (`overlay/etc/upper/*` and `home/$LIVE_USER`).
  After this, nothing that seeds an installed disk can carry them.

What this buys the installer is deletion. `remove_live_user()` goes; an installed disk's lower has
no `live` and its fresh `/var` has none either. `accountsetup` gains a post-condition in its place:
the target's `passwd` must not name `LIVE_USER`, and the job fails if it does. `imageidentity`
writes `20-autologin.conf` only when autologin was actually chosen ([plan/26](26-installer-ux-tweaks.md)
§4), because there is no longer a drop-in to cancel.

**Assertions:**

- The root EROFS has no `LIVE_USER` in `/etc/passwd` and no `plasmalogin.conf.d/10-autologin.conf`.
- The var partition has both.
- `var.tar.zst` has neither.

**An upper `passwd` shadows the lower one after an update.** This is not new: every installed
system has had a full upper `passwd` since the installer's first `useradd`. The image carries 66
`acct-*` files in `/usr/lib/sysusers.d`, so `systemd-sysusers` puts back any system user or group a
later release adds. Only supplementary memberships added to *existing* entries would not follow.
That is recorded in §14 and is not solved here.

## 6. Phase C — the installer tree becomes the desktop tree plus the tail

The extension is a *difference* between two trees (§7.2). It is correct only if the installer's
tree is the desktop's tree with things **added**, at identical versions. plan/20 made the installer
tree smaller than the desktop's on purpose. Every one of those removals now just becomes a deletion
the live view would ignore, so they go.

| plan/20 removal | Mechanism | Now |
|---|---|---|
| wallpaper collection, Spectacle, Discover, managed KCM | `#not-live` in `config/portage/sets/desktop` (52, 72, 102, 158) | Markers removed. `filter_set_file`'s parsing (`common.sh:1393`) is removed, and a test forbids the marker |
| ghostscript and its fonts | `kde-apps/thumbnailers -pdf` in `package.use/profile.installer` | Removed. `dev-qt/qttools linguist` stays: it only adds files, and the Calamares modules need it |
| Breeze's `Next`, the Emoji Selector, `/usr/share/i18n/SUPPORTED` | stage 50 §3i, §3k, §3m, live only | Removed. §3m's own comment says nothing on the medium reads SUPPORTED any more |
| the managed-mode QML front end | stage 40, live only (125–132) | Removed |
| podman + distrobox | `INCLUDE_DISTROBOX=0` in `installer.conf` | Removed. The profile inherits `build.conf` |
| `sysupdate.d/*.transfer` | stage 40 deletes them, live only (1721–1726) | The deletion is removed; the **mask stays** and lands in the upper. The 2219–2226 verify is inverted |

**What stays:** stage 50 §3j (GRUB, 68 MiB of tail files that are never executed), §3h (Qt Linguist
launchers) and §3n (IBM Plex faces). All three only touch files that exist in the installer tree
alone, so they shrink the extension and delete nothing from the product.

`FLATPAK_PREINSTALL=""` also stays on `installer.conf`. The store comes from the desktop build's
own artifact (§7.1) rather than being installed a second time.

**Two new invariants, both tested offline:**

- every atom in `desktop.lock` appears in `installer.lock` at the **identical** CPV;
- `expected-packages.installer.txt` ⊇ `expected-packages.desktop.txt`.

Without them the extension could override a desktop library with a different version of itself,
and the live session would run a mix of two releases that nothing ever tested.

`PAYLOAD_PROFILE` becomes **`BASE_PROFILE`**: "the target profile whose root this medium boots and
installs". It is still validated to exist, to be another profile and to have role `target`
(`common.sh:416-435`).

## 7. Phase D — assembling the medium

### 7.1 Stage 40: what is staged

The payload block (`40-configure.sh:1639-1710`) keeps its place and loses its bulk:

| | Today | Now |
|---|---|---|
| `root.erofs` | 2777 MiB copied into `/var/lib/immos-install` | **Not copied.** Stage 60 writes it into the root partition. The manifest records its sha256 and size with `"source": "partition"` |
| `uki.efi` | desktop UKI | Unchanged. It is the file installed on the target's ESP |
| `var.tar.zst` | 899 MiB, the desktop's whole `/var` | Replaced by **`var-base.tar.zst`**: the same tarball minus `lib/flatpak`. The rest of the desktop `/var` is about 1 MiB of ownership-bearing skeleton (`sss`, `polkit-1`, `plasmalogin`, …) plus `lib/immos/flatpak-preinstall.done` |
| the Flatpak store | inside `var.tar.zst` | **Unpacked** from the desktop `var.tar.zst` into `$TARGET/var/lib/flatpak`: the pinned store the desktop build installed, byte for byte, now the live session's own |

The Flatpak store and `var-base` both come from one desktop artifact, so the stick and a dd'd
`desktop.img` carry the same apps at the same pins by construction.

The stamps for stages 40 and 60 gain the sha256 of the desktop EROFS, UKI and `var.tar.zst`. Today
`stamp_write` (2876–2882) hashes none of them, so rebuilding the desktop at the same `VERSION` does
not re-run the installer's staging.

### 7.2 Stage 60: the extension and the upper, by difference

For the live role, stage 60 stops building an EROFS of its own tree.

1. **Extract the base.** `fsck.erofs --extract=<scratch> --preserve` of `out/immos_<v>.root.erofs`.
   This is the release artifact, not `/work/target`, which another clone may have rebuilt
   (two clones share the build volumes). Assert that its `os-release` `VERSION_ID` is `VERSION`.
2. **Diff.** A new `scripts/lib/tree-delta.py BASE NEW OUT` walks the installer tree (minus `/var`
   and the mount points) against the base. Per path it compares type, mode, uid, gid, rdev,
   symlink target, xattrs and sha256; mtimes are ignored. Output goes into `$VAR_STAGE`, never
   `$TARGET`, so re-running stage 60 is idempotent. `mkfs.ext4 -d` already carries the staged
   ownership into the image.

   | Path | Goes to | Rule |
   |---|---|---|
   | added or changed under `/usr` | `lib/extensions/immos-installer/usr/` | |
   | added or changed under `/etc` | `overlay/etc/upper/` | A path already in the upper wins. §5's split put it there from the installer's own `/etc`, so it already includes the change |
   | **deleted** (in base, not in new) | — | **Fails the build.** §6 is what makes this list empty |
   | changed outside `/usr` and `/etc` | — | Fails the build |
   | *changed* (not added) path outside an allowlist | — | Fails the build. The allowlist is the caches stage 40 regenerates (`ld.so.cache`, icon, mime and desktop-file caches) and the files the installer deliberately edits (`xdg/kdeglobals`). Drift between the two trees is loud, not silent |
   | `usr/lib/os-release`, or units, `sysusers.d`, `tmpfiles.d` or udev rules in the extension | — | Fails the build: sysext cannot deliver early-boot resources |

   It prints a size report by top-level directory. Its fixture test runs offline in `tests/`.
3. **Stamp the extension.** Write
   `usr/lib/extension-release.d/extension-release.immos-installer` with `ID=immos`,
   `VERSION_ID=<v>` and `ARCHITECTURE=x86-64`.
4. **Build the live UKI** (§8).
5. **Size the medium from its contents.** The root slot is the EROFS size rounded up to 64 MiB, and
   the ESP is `MEDIUM_ESP_SIZE_MIB` (256), because it holds one UKI. The var partition is the
   existing measured need plus headroom (204–215). The *installed* layout keeps `ESP_SIZE_MIB` and
   `ROOT_SLOT_SIZE_MIB` untouched. That removes the blocker [plan/20 §3](20-installer-slimming.md)
   hit, where the medium could not shrink its slot because the same key sized the target's.
6. **Write the root.** `dd` the desktop EROFS into `live_root_<v>`, then read the partition's first
   `size` bytes back and compare their sha256 with the manifest.
7. **Assert on the built var image**, not the staging tree. This is the lesson of `--all-root`
   ([plan/16](16-installer.md)): the upper's `polkit-1/rules.d` is `0700 polkitd:polkitd`, the
   extension is root-owned, and `lib/immos/flatpak-preinstall.done` is present, so the base's
   firstboot unit stays quiet on the stick.

## 8. One UKI or two

**Two, and they differ in one section.** A UKI's `.cmdline` is sealed: `loader.conf` says
`editor no` ([plan/11](11-kernel-boot-audit.md)), and systemd-stub ignores loader-supplied options
under Secure Boot. That cmdline names `root=PARTLABEL=root_<v>`, and after §4 it also names `var`
and `esp`. The stick's partitions are `live_*` on purpose (plan/33 §2). So the stick needs a
different command line, and a different command line means a different UKI.

It does not need a different kernel or initrd. Stage 60 **re-wraps the desktop UKI**:

- `objcopy --dump-section` extracts `.linux`, `.initrd`, `.osrel` and `.uname` from
  `out/uki/immos_<v>.efi`, plus `.splash` when present (0.3.1's has none).
- The three label tokens in the desktop `.cmdline` are substituted, and the build asserts each is
  replaced exactly once.
- `ukify build` produces the live UKI, and the build asserts that every section except `.cmdline`
  is byte-identical to the desktop UKI's.

The installer profile stops building an initrd and a UKI of its own in stage 40. The stick boots
exactly the kernel and initrd it installs.

| Alternative | Why not |
|---|---|
| One multi-profile UKI (systemd 257+), a live profile beside the installed one | Every installed machine's boot menu gains a "live" entry that cannot boot there |
| The desktop UKI plus a Type #1 loader entry whose `options` replace the cmdline | systemd-stub honours that only with Secure Boot off, which breaks plan/08 roadmap item 2 |
| Shared partition names, so one cmdline fits both | This is the two-disk bug plan/33 §2 exists to fix |

## 9. Phase E — the Calamares jobs

| Module | Change |
|---|---|
| `imagedeploy` | The source is the block device behind `/`. Its partlabel is cross-checked against the rendered `live_root_<v>`, and exactly `manifest.root_erofs.size` bytes are copied. The sha256 is computed **while** copying and a mismatch fails the job: one read of the stick instead of today's verify-then-write two. On erase, `/var` is seeded from `var-base.tar.zst`, then `/var/lib/flatpak` is copied from the live system with hardlinks preserved and progress reported. On keep, both are skipped, as the template is today ([plan/33 §7](33-reinstall-keeping-files.md)) |
| `imagebootloader` | Unchanged: the UKI still comes from `payloadDir/uki.efi`, systemd-boot from the target's `/usr`. The header comment, "the files come from the payload", is corrected |
| `accountsetup` | `remove_live_user()` is deleted. A post-condition fails the job if the target's `passwd` names `LIVE_USER` (§5) |
| `imageidentity` | `20-autologin.conf` is written only when autologin was chosen |
| `greeting` | `internet` stays out of `required`: the apps are still on the stick |
| `appsetup` | Unchanged. It still installs the chosen extras and then runs `flatpak update` |

**Flatpaks installed in the live session come along.** The live store is the install's source, so an
app added from Discover on the stick is on the installed machine too. This is intended, and the
README says so. plan/20 §4.3 removed Discover because a live install was "discarded … twice over";
neither discard happens any more.

**The disk page is unaffected.** `liveMediumDisk()` (`DiskConfig.cpp:94-118`), `check_target()` and
`Requirements.cpp` all identify the stick by the device behind `/`, which is still the stick's root
partition.

## 10. Phase F — the live session

- **The installer icon**, ported by hand from `ec691b9` on `installer-desktop-shortcut`. That commit
  cannot be cherry-picked: its `plan/33-*.md` clashes, and it predates plan/33's stage 40.
  - `config/calamares/system/installer-desktop.desktop.in` is the autostart entry minus its
    autostart keys, installed at `home/$LIVE_USER/Desktop/<ID>-installer.desktop`, mode 0755,
    chowned to the uid:gid `useradd -m` gave the live user (parsed out of the target's own
    `/etc/passwd`, since the builder has no account of that name). Stage 40 reads it back —
    present, executable, running `pkexec calamares` — and the path joins the leak list every
    non-installer profile is refused.
  - The installer layout writes the task manager's `launchers` explicitly empty
    (`writeConfig("launchers", [])`). A deleted write would leave the KConfigXT defaults, and
    `KService` resolves them silently rather than leaving a hole.
  - That exact string is asserted in the script, in stage 40's read-back and in
    `tests/test-installer.sh` (both the write and a zero-count of `applications:` URLs in the
    comment-stripped script).

  Autostart stays: the stick still opens the installer.

  **The panel stays empty — decided again, on this document's premise.** `ec691b9` emptied it
  partly because two of the four stock pins were dead on its medium: Discover was `#not-live` and
  no browser was preinstalled. Neither holds here — §6 puts Discover back on every profile and
  §7/§9 give the live session the installed disk's own Flatpak store, Firefox included — so all
  four stock pins (System Settings, Discover, Dolphin, Firefox) would resolve. The question was
  put to the owner on that premise and the answer was the same: empty. The stick exists to
  install, and autostart, the desktop icon and the application menu already put the installer in
  front of the user. The layout is live-only (it reaches `/usr` through the extension, §7), so an
  installed machine keeps upstream's four pins.
- **What the session gains, with no further work:** the whole product — the wallpaper collection,
  Spectacle, Discover, KInfoCenter, distrobox and podman (the live user already has subuid/subgid
  ranges) — and Firefox, Okular, Gwenview, Ark and KWrite. `live_var` grows to fill the stick on
  first boot, as it does today, so what the live user saves survives a reboot.
- **What it shows that it did not:** "Managed Settings" in Kickoff, from the base. Nothing on a stick
  is ever enrolled, and the entry is harmless.

## 11. Size, estimated and measured

| | 0.3.1 before | Estimated | Measured |
|---|---:|---:|---:|
| live root | 2366 MiB installer EROFS | 2777 MiB desktop EROFS | 2773 MiB desktop EROFS, byte for byte, in a 2816 MiB slot |
| payload root EROFS | 2777 MiB | — | — |
| Flatpaks | 899 MiB `.zst` inside the payload | ~2757 MiB deployed in `live_var` | 2749 MiB deployed in `live_var` |
| extension | — | tens of MiB (plan/16 §2.2: 107.6 MiB tail, 68 of it GRUB and deleted) | 36 MiB, 689 paths (`usr/lib64` 25 MB, `usr/share` 7 MB, `usr/bin` 3 MB) |
| `live_var` | 5120 MiB, fixed | ~3200 MiB | 2846 MiB staged, 3051 MiB needed, 3328 MiB partition (+256 MiB headroom, rounded to 64) |
| UKIs | 60 + 60 MiB | 60 + 60 MiB | 60 + 60 MiB (the live UKI on `live_esp`, the desktop UKI in the payload) |
| **`.img`** | **12290 MiB** | **~6.3 GiB** (256 + ~2816 + ~3200) | **6402 MiB** (256 + 2816 + 3328, plus the GPT) |
| **`.img.zst`** | **4769 MiB** | **~3.1 GiB**: close to `desktop.img.zst` (3022 MiB), which holds the same root and store | **3079 MiB**, against `desktop.img.zst` at 3010 MiB from the same build |

The raw number matters as much as the compressed one. An 8 GB stick holds 7629 MiB: 6402 MiB fits
with 1227 MiB to spare, and 12290 MiB never did. Stage 60 sizes `live_var` from what it holds
rather than from `VAR_SIZE_MIB`, and refuses any medium over 7168 MiB, so a store that grows past
the stick fails the build instead of the user. An erase install of the measured medium, from a
KVM guest's virtio disk, takes about six minutes. The measured column is the build at `de78ad3`,
2026-09-25.

## 12. Tests

| | |
|---|---|
| `test-profiles.sh` | `fstab.in` renders no `PARTLABEL` for any profile; the cmdline names `live_var`/`live_esp` for the installer and `var`/`esp` for desktop and console. The identity strings are unchanged |
| `test-installer.sh`, the payload | 40–82, 126–143, 338–346 and 3100–3107 are rewritten for `BASE_PROFILE`, `var-base`, `source: partition` and the in-place hash. The leak list (3725–3731) gains `var/lib/extensions` and the upper's live files. It asserts `remove_live_user` is gone and the post-condition present |
| `test-installer.sh`, the superset | No set contains `#not-live`; `desktop.lock` ⊆ `installer.lock` at identical CPVs; `expected-packages.installer.txt` ⊇ `expected-packages.desktop.txt`; `profile.installer` changes no USE flag of a desktop package except `qttools`' additive `linguist` |
| new `test-tree-delta.sh` | Fixture trees: an addition under `/usr` and one under `/etc` are routed; a deletion, a change outside `/usr`/`/etc`, a unit and an `os-release` each fail; an allowlisted cache passes; an existing upper file wins |
| `test-image-layout.sh` | The medium's geometry comes from its contents, and the installed layout is unchanged |
| stages 40, 50, 60 | The assertions named in §4, §5, §7 and §8, each read from the **built** image where one exists |

## 13. Locks and the build

- **Relock `installer`.** Removing the markers and `INCLUDE_DISTROBOX=0` adds atoms, and stage 30
  wipes the installer target when `target_closure_hash` moves. It remerges from `/cache/binpkgs`.
- **Restamp `desktop` and `console`.** Editing the set files moves `portage_config_hash`; the fix is
  the three header lines ([plan/33 §12](33-reinstall-keeping-files.md)).
- **Build order:** desktop through stage 70 (Phases A and B change it), then installer through
  stage 60. As today, the installer needs a desktop build at the same `VERSION`.

## 14. Known limits and risks

- **A machine dd'd from an older `desktop.img` that uses `live` as its daily account loses it on the
  next update.** Its `passwd` came from the lower, which no longer carries the user. There is no
  migration unit. Those machines predate the installer, and the release note gives the one-line
  fix. Revisit if anyone reports it.
- **Supplementary group memberships added by a later release to an existing entry** do not reach an
  upper `passwd`/`group`. This is true of every installed system already (§5).
- **The live session can change the install.** Flatpaks added on the stick are copied (§9). A store
  corrupted on the stick would be copied too; the job copies, it does not verify apps.
- **Sticks made before this document** still carry the payload and install it, as before.
- **Fixed during this document's implementation: a stray `/etc/udev/hwdb.bin`, on every profile,
  not specific to the installer.** `systemd-hwdb update --usr` (stage 40) builds
  `/usr/lib/udev/hwdb.bin`, the one meant to ship. But `sys-apps/systemd`'s own `pkg_postinst`
  also runs an unqualified `systemd-hwdb --root=$ROOT update` at EMERGE time, into `$ROOT` =
  this build's own `$TARGET`, writing a SECOND copy to `/etc/udev/hwdb.bin`. That copy's
  compiled entries carry the source path of every hwdb.d fragment that fed it — so it embeds
  the build's own work-volume path (`/work/target` or `/work/target-installer`), which is why
  a tree-diff between two separately-built profiles ever saw it as "changed" at all: it is a
  build-specific artifact, not a difference in what was installed. It was first misdiagnosed as
  filesystem readdir-order nondeterminism (an earlier pass compared file lists across two
  independently-populated roots and found the source .conf fragments byte-identical); that
  explanation was wrong; the actual cause is the emerge-time copy's embedded build path.
  Worse than merely extra weight: systemd's `HWDB_BIN_PATHS` tries `/etc/udev/hwdb.bin` BEFORE
  `/usr/lib/udev/hwdb.bin`, so the copy that shipped was the *stale, build-tainted* one, not the
  fresh one this stage rebuilds every time — and `systemd-hwdb-update.service`
  (`ConditionPathExists=|/etc/udev/hwdb.bin`) would have rewritten ~13 MB into every installed
  machine's `/etc` upper after every future update, for a file the image never needed at all.
  Fixed by deleting `/etc/udev/hwdb.bin` in stage 40 right after the `--usr` rebuild, verified
  three ways: the path is gone, `/usr/lib/udev/hwdb.bin` exists and is nonempty, and it contains
  no `/work/` byte sequence.
- **Built, not yet driven**, until:
  - `run-vm.sh` has booted the stick (autologin, `systemd-sysext status` listing
    `immos-installer`, Firefox launching);
  - an erase install has produced a `root_<v>` whose sha256 equals `out/immos_<v>.root.erofs`,
    with no `/usr/bin/calamares`, no `live` user, the created user logged in, the Flatpaks
    running and `immos-update status` reporting a normal installation;
  - a `--extra-disk-keep` reinstall has kept files, apps and settings.

## Changes to other documents

| Document | Change |
|---|---|
| [16-installer](16-installer.md) | §3.3's guarantee is now held by the medium's structure as well as the audit; §3.4's "indistinguishable" is now "identical bytes"; §5.1 step 3 copies a partition, not a file; §5.4's live-user removal is gone; §7.4's sizes and §7.5's shared layer are superseded by §3 and §11 here. Phase B's ISO gets simpler: one root, not two |
| [20-installer-slimming](20-installer-slimming.md) | A header: superseded by 34 §6. The live root is the product, so the medium is slimmed by carrying the product once rather than by trimming a second copy of it |
| [33-reinstall-keeping-files](33-reinstall-keeping-files.md) | §2's labels are the same names, carried by the cmdline instead of fstab (§4 here) |
| [01-architecture](01-architecture.md), [04-image-and-boot](04-image-and-boot.md) | fstab carries no partitions; "First boot & default user": the live user lives on `/var` |
| [08-roadmap](08-roadmap.md) | The baked-`live`-user tradeoff row (101) is resolved. Line 23's "the ISO would reuse the *same* root EROFS … did not survive" is true again |
| `config/profiles/installer.conf` | Header and the plan/20 drop table rewritten; `BASE_PROFILE`; `VAR_SIZE_MIB` re-measured |
| `config/calamares/README.md` | "The payload" becomes "What the stick installs from"; the module table; live-installed Flatpaks carry over |
| `docs/build.md` (26–44, 72–80), `docs/pipeline.md` (53), `docs/testing.md` (51–87), `docs/pinning.md` (53) | Profiles, artifacts, the stage 40/60 rows, `#not-live`, the VM walk-through |
| README | A row for this document |
