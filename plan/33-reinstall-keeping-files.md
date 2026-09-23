# 33 — Reinstalling without losing anything

Every install this installer has ever done is a whole-disk erase ([plan/24](24-installer-disk-page.md)).
That is the right default for a new machine and the wrong one for the machine that already runs
this distro and needs a fresh system under it: a boot that no longer comes up, an update that went
badly, a medium newer than anything sysupdate reached. Today the only answer to any of those is to
lose the accounts, the files in them, the Flatpak apps and every change made to `/etc`.

All of that lives on one partition. `var` holds the `/etc` overlay upper, `/var/home`,
`/var/roothome`, the Flatpak store and `/var/lib/<id>`, and nothing the user owns lives anywhere
else ([plan/01](01-architecture.md)). A reinstall that keeps `var` and replaces the rest is
therefore not a new kind of machine: it is exactly what `systemd-sysupdate` does on every update —
a new root image, a fresh boot entry, the same `/var`. The installed result is a state the update
path already produces and supports, which is the whole argument for building this at all.

This document adds that choice to the disk page — **"Keep my files, apps and settings"**, ticked
by default when the chosen disk already holds an install — and makes every page and job after it
tell the truth about what happens. The words the user reads never say `/var`, "partition table",
"overlay" or anything like them.

It also fixes the thing that made the feature impossible to ship without it (§2): the installer
stick and an installed disk carry the same partition names, and keep mode is precisely the case
where both are in the machine at once.

## 1. What was decided before this was written

| Question | Answer |
|---|---|
| The accounts page, when keeping | Says the accounts are kept. No account is created, nothing is enrolled or joined, and the hostname and autologin are left alone |
| The language, location and keyboard answers, when keeping | Not applied. The kept system keeps its own settings; those pages' answers configure the installer session only, and the summary says so |
| The checkbox's default | **Ticked** when the disk can be kept — the choice that cannot lose anything is the one the user has to act to leave |
| `run-vm.sh --extra-disk-keep` | Keeps the extra disk beside the image across runs, and `run-vm.sh` learns to boot a qcow2 directly so the installed disk can be used between installs |
| The partition-name clash | Fixed here, as §2, before anything else |

## 2. Phase A — the stick gets its own partition names

[plan/16 §10 1b](16-installer.md) recorded this and deliberately deferred it: the installed root
and var carry `root_<version>` and `var`, the same PARTLABELs the live medium's own partitions
carry, because §3.4 forbids profile-suffixing those strings. With two disks attached,
`/dev/disk/by-partlabel/<name>` resolves to whichever device udev saw first, independently per
partition.

Phase A of plan/16 met it from the installed side — the finished page says to remove the medium.
Keep mode meets it from the other side, and there it is not a curiosity: booting the installer on
a machine that already has this distro is the *definition* of keep mode, and the live initrd's
`root=PARTLABEL=root_<v>` and fstab's `PARTLABEL=var` can bind the installed disk. The live
session then either cannot find its payload (it is under the stick's `/var`) or holds the target's
`var` mounted, so the job cannot release it. `run-vm.sh --extra-disk-keep` reproduces it on the
first try.

The fix plan/16 named is the one taken: **a `PROFILE_ROLE=live` image's own partitions are
`live_esp`, `live_root_<v>` and `live_var`.** §3.4 does not bind them, because a live medium is
never a sysupdate target. Everything that describes an *installed* system is untouched: `esp`,
`root_<v>`, `_empty`, `var`, `ROOT_PARTLABEL`, `UKI_NAME`, and every string `disksetup`,
`imagedeploy`, the manifest and sysupdate use.

| File | Change |
|---|---|
| `scripts/lib/layout.sh` | New `layout_names ROLE VERSION`, setting `NAME_ESP NAME_ROOT NAME_VAR` — `target`: `esp`/`root_V`/`var`; `live`: `live_esp`/`live_root_V`/`live_var`; any other role dies. `emit_sfdisk_script VERSION [ROLE]` defaults to `target` and takes its names from it; slot B stays `_empty`. `emit_install_sfdisk_script` always uses `target` — an installer only ever makes an installed machine. Still self-contained: no `$REPO`, no `load_config` |
| `scripts/lib/common.sh`, `init_paths()` | After `ROOT_PARTLABEL`, `layout_names "$PROFILE_ROLE" "$VERSION"` sets `IMG_ESP_PARTLABEL`, `IMG_ROOT_PARTLABEL`, `IMG_VAR_PARTLABEL` — *the labels this profile's own image carries*, equal to the identity names for `target`. Confirm `PROFILE_ROLE` is loaded before `init_paths` runs (`tests/test-profiles.sh` calls it per profile) |
| `config/rootfs/etc/fstab` → **`fstab.in`** | `PARTLABEL=@IMG_VAR_PARTLABEL@` and `PARTLABEL=@IMG_ESP_PARTLABEL@`; the header comment names `@IMG_ROOT_PARTLABEL@`. `install_rootfs_overlay` already renders `*.in` |
| `scripts/stages/40-configure.sh` | The three `IMG_*_PARTLABEL` join the export near the top, before `install_rootfs_overlay`. `CMDLINE` becomes `root=PARTLABEL=$IMG_ROOT_PARTLABEL`. The payload checks (manifest, `disksetup.conf`, `imagedeploy.conf`) keep `ROOT_PARTLABEL`. New verify: the rendered `/etc/fstab` names `$IMG_VAR_PARTLABEL` and `$IMG_ESP_PARTLABEL`, and a `live` one does **not** name `PARTLABEL=var` |
| `scripts/stages/60-image.sh` | `emit_sfdisk_script "$VERSION" "$PROFILE_ROLE"`. New verify after `sfdisk --verify`: `sfdisk --dump "$IMG"` carries `name="$IMG_ROOT_PARTLABEL"` and `name="$IMG_VAR_PARTLABEL"`. Filesystem labels (`-L var`, `-n ESP`) are unchanged — nothing mounts by filesystem label |

Only the installer's own image changes. The desktop and console outputs are byte-identical — the
rendered fstab is the same text as the file it replaces, which is checked by rendering `fstab.in`
for `target` and comparing.

## 3. What the disk page looks like now

The row for a disk that holds an install says so, by name and version, in place of the partition
labels it used to list; the panel under the list gains one row, in the slot the encryption row
used to occupy.

```
 ┌───────────────────────────────────────────────────────┐  a disk that can be kept
 │ Where should Immutable OS be installed?    ⟳ Check again│
 │ A disk that already has Immutable OS on it can keep    │
 │ your files, apps and settings. Everything else on the  │
 │ disk you choose is erased.                             │
 │ ● VirtIO disk      /dev/vdb · 42 GB · Immutable OS 0.3.0│  ← selected
 │ ⊘ VirtIO disk      /dev/vda · 12 GB   Not eligible     │
 │ ─────────────────────────────────────────────────────│
 │ THE DISK WILL BE SET UP LIKE THIS                      │
 │ ▓▒░████████████████████████████████████████████████████│
 │ ■ Boot 1.1 GB ■ System 6.4 GB ■ Reserved for updates   │
 │ 6.4 GB ■ Your files (kept) 28 GB                       │
 │ ⓘ The system on this disk is replaced with Immutable   │
 │   OS 0.4.0. Its accounts, files, apps and settings are │
 │   kept.                                                │
 │ ☑ Keep my files, apps and settings                     │
 └───────────────────────────────────────────────────────┘
        ← Back            Next →   (opens "Reinstall on this disk?")
```

**The keep row replaces the encryption row rather than joining it.** The page is the tightest in
the installer — [plan/31 §2](31-installer-sidebar-and-defaults.md) fought for twenty pixels of it —
and a sixth block would put the second disk behind a scrollbar again. Encryption cannot apply to a
partition that is being kept as it is, so on a disk that offers keeping the row that says *not yet
available* has nothing to say. On every other disk it is drawn exactly as before.

**Which row shows depends on the disk, not on the tick.** Toggling the box never adds or removes a
block, so nothing on the page moves under the cursor — the rule plan/24 §1a set for the list. The
subheadline follows the same rule for the same reason: it depends on whether *any* disk can be
kept, not on the current selection.

**Unticked is the plain erase, named properly.** On a disk that holds an install, the warning
names what goes: *Immutable OS 0.3.0 and everything saved on it will be deleted, including its
accounts, files, apps and settings* — rather than *4 partitions will be deleted, including esp*.

**A disk that holds an install which cannot be kept** (§4's `refuse`) shows the row disabled, with
*Not possible on this disk* beside it, and the warning gains the reason in one sentence.

## 4. One definition of "can this disk be kept": `disk-layout inspect`

It belongs in `lib/layout.sh`, for [plan/24 §4](24-installer-disk-page.md)'s reason: it is a
statement about the layout, and the GPT type GUIDs must stay in that one file. The page and the job
both run it, so they cannot disagree about a disk.

```
disk-layout inspect --device DEV --esp-mib N --slot-mib N      # stdin: `sfdisk --dump DEV`
```

A pure text function, `inspect_installed_layout DEVICE ESP_MIB SLOT_MIB`: reads the dump on stdin,
has no side effects, and is unit-tested against fixtures. It prints `key=value` lines and exits 0
whenever it completed an analysis (2 on a usage error):

- **`verdict=none`** — no partition is both named `var` and typed `GPT_TYPE_VAR`. Not an install;
  the page does exactly what it did before this document.
- **`verdict=refuse`** with `reason=`:
  - `table` — the label is not `gpt`;
  - `layout` — not exactly partitions 1–4 with ascending starts, typed and named p1 `ESP`/`esp`,
    p2 and p3 `ROOT_X64` named `root_<v>` or `_empty` (at least one `root_<v>`), p4 `VAR`/`var`;
  - `esp-size` — p1 is smaller than `ESP_MIB`;
  - `slot-size` — p2 or p3 is smaller than `SLOT_MIB`.
- **`verdict=keep`** with `esp=1 slot=2 spare=3 var=4` and `esp_mib= slot_mib= spare_mib=
  var_mib=`. The new root always goes into p2, the slot a fresh install uses.
- **`installed=<highest root_<v> by sort -V>`** whenever a `root_*` name exists, on keep and
  refuse alike.

The partition number comes from the node, by stripping the `--device` prefix and then an optional
`p` — `/dev/nvme0n1p2`, `/dev/sda2` and a scratch file's `disk.img2` all give 2. GUIDs compare
case-insensitively. Sizes are `size=` sectors times `sector-size:`, which defaults to 512. `inspect`
joins the CLI's `usage()`.

The minimums are this build's `ESP_SIZE_MIB` and `ROOT_SLOT_SIZE_MIB`, not the size of the image
being written: a disk whose slots are smaller than the build's is a disk that future updates will
not fit either, and keeping it would only move the failure to the next sysupdate.

## 5. The page (`distro-calamares-disk`)

**`DiskModel.h/.cpp`.** `Entry` gains `enum class Keep { None, Offered, Refused }`, `keep`,
`installedVersion`, and `keptEspBytes`/`keptSlotBytes`/`keptSpareBytes`/`keptVarBytes`.
`ContentsRole` for a row with `keep != None` is `productName() + " " + installedVersion` — the name
the user knows the disk by, not `esp, root_0.3.0, _empty, …`.

**`DiskConfig.h/.cpp`.**

- `layoutHelper` is read from the configuration with `Calamares::getString`. The `configNumber`
  call sites stay at five: that count is pinned by the test ([plan/24 §11](24-installer-disk-page.md)).
- `inspectDisk(Entry&)`, called from `enumerate()` **only** for installable rows whose lsblk
  children include partlabel `var`. It runs `sfdisk --dump <node>` (5 s timeout), then the helper's
  `inspect` with the dump on stdin (5 s), passing the `espSizeMiB`/`rootSlotSizeMiB` the page
  already reads. `keep` **and** p4's lsblk `fstype == "ext4"` is `Offered`; `refuse`, a keep
  without ext4, or any process failure is `Refused`, with a `cWarning` for the failures; `none` is
  `None`. No GUID appears in C++.
- `bool m_keepData`. `setCurrentIndex()` sets it to `selected.keep == Offered` — ticked by default
  — and emits `keepDataChanged`. `rescan()` restores the selection through `setCurrentIndex`, so it
  re-defaults too.
- New properties, each `CONSTANT` or notifying a signal that is actually emitted:
  - `keepOffered` — the selected row's `keep != None`. NOTIFY `planChanged`.
  - `keepAvailable` — `== Offered`. NOTIFY `planChanged`.
  - `keepData` — READ/WRITE, NOTIFY `keepDataChanged`. `setKeepData(bool)` is ignored unless
    available; it calls `setConfirmed(false)` and emits `keepDataChanged`, `planChanged` and
    `retranslated()` — the confirmation strings follow it, the same loosening `setCurrentIndex()`
    already makes for `confirmSubtitle`.
  - `keepLabel`, `keepUnavailableText` — NOTIFY `retranslated`.
- Branched on *keeping* (`keepAvailable && m_keepData`): `plan()` draws the four segments from the
  kept sizes, the last labelled *Your files (kept)*; `lossSummary()`, `confirmTitle()`,
  `confirmAcceptLabel()` and `prettyStatus()` take §9's words, the two confirmation strings moving
  out of line. `subheadline()` branches on "any installable row is `Offered`".
- `publish()` adds `diskKeepData` = `keepAvailable && m_keepData`, and its comment about the
  contract being three keys is updated to four.

**`qml/Disk.qml`.** The encryption row gets `visible: !disk.keepOffered`. The keep row sits in the
same slot, `visible: disk.keepOffered`: the shared `CheckBox` (`label: disk.keepLabel`,
`checked: disk.keepData`, `onToggled: function (v) { disk.keepData = v; }`,
`enabled: disk.keepAvailable`, 0.5 opacity when not), and a muted `textXs` hint
`disk.keepUnavailableText` when not available. The loss Alert takes the design system's info tone
while keeping — `statusInfoBg`, border `ds.mix(ds.statusInfo, ds.statusInfoBg, 0.35)` — and the
warning tone otherwise. The dialog's accept action is `icon.name: disk.keepData ? "view-refresh" :
"data-warning"`. No `qsTr()`, and no new block.

**`config/calamares/modules/disk.conf.in`** gains `layoutHelper:
"/usr/libexec/@DISTRO_ID@-disk-layout"`, the same path `disksetup.conf.in` names.

## 6. The job that keeps (`disksetup`)

`run()` reads `keep = bool(gs.value("diskKeepData"))`. `check_target()` and `release_disk()` run
unchanged on both paths — the checks that protect data do not get a keep-mode exemption, and a
Plasma session will have automounted the target's `var` exactly as it automounts anything else.

The keep path, in order. **Nothing is written until step 3.**

1. **`inspect_layout(conf, device)`** — `sfdisk --dump`, then the helper's `inspect` with the
   configuration's `espSizeMiB` and `rootSlotSizeMiB`. Anything but `verdict=keep` is a
   `SetupError`. The page asked the same question; the job asks it again, because a job that
   writes a disk does not take a string's word for it (plan/24 §6).
2. **`check_kept_files(var_node, conf)`** — `e2fsck -p`, failing on `rc & ~3`; mount `-t ext4 -o
   ro` on a temporary directory; require the directories `overlay/etc/upper` and
   `lib/<distroId>`; unmount in `finally` and remove the directory. The first is what makes it
   this distro's `/var`; the second is created by the installer's hostname stamp and by the
   `distro-state` tmpfiles entry on every boot, so every install has it.
3. **`keep_disk(device, layout, conf)`** — `sfdisk --part-label DEV <spare> _empty` **first**, then
   `sfdisk --part-label DEV <slot> <rootPartLabel>`: the spare may already carry the very
   `root_<v>` being written, and two partitions with one label is the ambiguity §2 exists to
   remove. Then `settle_for` all four nodes, `wipefs -a` the spare and the ESP, and `make_esp()`.
4. **`publish_partitions(esp, root_a, root_b, var, conf)`**, shared with the erase path — the same
   dicts as today, so `imagedeploy` and `imagebootloader` cannot tell the two paths apart.

Refactored so that the assertions plan/24 wrote still hold: `make_esp()` holds the **only**
`mkfs.vfat` literal and the erase path's `mkfs.ext4` stays the only ext4 one; the keep path never
calls `write_table` and never `wipefs`es the whole device; no GPT GUID appears in `main.py`.
`disksetup.conf.in` gains `distroId: "@DISTRO_ID@"`.

Its failures say that nothing has been changed, because on this path that is true and it is the
first thing somebody needs to know: the layout that cannot be kept (*…cannot be kept… Nothing has
been changed. Start the installer again and choose to erase the disk instead.*), the filesystem
e2fsck could not repair (*…has errors the installer could not repair…*), and the partition that is
not this distro's (*…does not hold files from this operating system…*).

## 7. Every other job, and the one that had to go

| Job | Change |
|---|---|
| `imagedeploy` | Under `diskKeepData`, skip the `var.tar.zst` extraction and the early `/etc/hostname` write, with a `debug()` for each. The directory belt-and-braces stays |
| `imagebootloader` | Before `efibootmgr --create`, list `efibootmgr` and skip creation when an entry with the same label already names the ESP's PARTUUID (`blkid -s PARTUUID -o value`, compared case-insensitively). Right in both modes: a kept ESP keeps its PARTUUID and its NVRAM entry is still valid, while an erase makes new PARTUUIDs and never matches |
| `localesetup`, `keyboardsetup`, `imageidentity` | `if diskKeepData: debug(...); return None` at the top of `run()`. For `imageidentity` it is not a nicety: its machine-id check would **truncate the kept machine-id** |
| `accountsetup` (`main.py.in`) | Under keep, nothing but the `finally` that unlinks the secrets file. Otherwise, a new `remove_live_user(root)` at the end: `in_target(root, ["userdel", "-f", "-r", "@LIVE_USER@"])`, warning on failure — the stock job's own tolerance |
| stock `removeuser` | **Gone from `settings.conf.in`'s `exec:`, and `modules/removeuser.conf.in` is deleted.** It runs `userdel -f -r <live>` unconditionally (calamares-3.4.2, `RemoveUserJob.cpp`), and a stock module cannot be told to stand down. On a kept disk installed by `dd`-ing the factory image, `live` may be the only account there is, and `-r` deletes its home. Stage 40 dies if `settings.conf` names it |
| `appsetup` | `install_refs` passes `--or-update`, so a kept store that already has one of the selected apps does not fail the whole batch |

Folding `removeuser` into `accountsetup` keeps the order plan/16 §5.4 relied on — the real account
exists before the live one goes — and moves the live user's removal into the one job that already
runs `useradd` and `chpasswd` in the same chroot.

## 8. The pages after the disk

**Accounts (`distro-calamares-accounts`).** A new `AccountsViewStep::onActivate()` calls
`m_config->setKeeping(gs->value("diskKeepData").toBool())`. While keeping, `isAtBeginning()` and
`isAtEnd()` are `true` and `nextEnabled()` is `true`: one screen, nothing to fill in. `setKeeping(true)`
with a live managed enrolment runs the existing `releaseEnrolment()` path — the same one leaving
managed mode takes — and emits `keepingChanged`, `stepChanged` and `nextEnabledChanged`. New
properties: `keeping` (NOTIFY `keepingChanged`), `keptHeading` and `keptBody` (NOTIFY
`retranslated`). `Accounts.qml` gains a block `visible: accounts.keeping`, styled as the chooser's
heading and lede; the chooser becomes `visible: accounts.onChooser && !accounts.keeping`, and the
fields likewise. `publish()` while keeping writes `accountsMode: "kept"` and every identity key
empty or false — hostname, username, autoLogin, managed\*, domain\* — deletes any secrets file an
earlier forward pass left, and publishes `accountsSecretsPath: ""`. The jobs key off `diskKeepData`
alone; `"kept"` is for the log.

**Language, location, keyboard.** Each `*Config::prettyStatus()` returns *Kept as it is on this
computer* when GlobalStorage's `diskKeepData` is true. The pages own their words — the summary and
the finished page draw other steps' `prettyStatus()` and must not grow a vocabulary of their own
(plan/28 §6) — so there is no row filtering in `review` or `done`. Each gains the `GlobalStorage.h`
and `JobQueue.h` includes.

**Summary (`distro-calamares-review`).** A bug first: `eraseTitle()` reads GlobalStorage's
`"device"`, which nothing has ever published, so the one sentence this page exists for has always
read *This erases the selected disk completely*. It reads **`"diskDevice"`**. Then a `keeping`
property, set in `collect()` from `diskKeepData` (NOTIFY `rowsChanged`); `eraseTitle` and
`eraseBody` branch on it, and `Review.qml`'s panel takes the warning tone while keeping and the
danger tone otherwise.

**Finish (`distro-calamares-done`).** `collect()` reads `diskKeepData` into `m_keeping` and emits
`retranslated()`; `pageTitle()` and `pageLede()` branch on it. Each stays one line —
[plan/32](32-installer-finish-and-lockup.md) left this page ten pixels of slack.

## 9. The words

English sources. Every Qt string needs its entry in all eight catalogues.

| Where | Erasing | Keeping, or a disk that holds an install |
|---|---|---|
| Disk checkbox | — | Keep my files, apps and settings |
| Disk hint, cannot keep | — | Not possible on this disk |
| Disk subheadline, one disk | (unchanged) | %1 is already on it. You can reinstall it and keep your files, apps and settings. |
| Disk subheadline, several | (unchanged) | A disk that already has %1 on it can keep your files, apps and settings. Everything else on the disk you choose is erased. |
| Loss Alert, keep ticked | — | The system on this disk is replaced with %1. Its accounts, files, apps and settings are kept. *(%1 = VersionedName)* |
| Loss Alert, install on disk, unticked | — | %1 and everything saved on it will be deleted, including its accounts, files, apps and settings. *(%1 = product + installed version)* |
| …and when it cannot be kept | — | This disk was set up in a way this version of %1 cannot reuse, so they cannot be kept. |
| Plan legend, fourth segment | Your files | Your files (kept) |
| Confirmation title / accept | (unchanged) | Reinstall on this disk? / Reinstall |
| Disk row on the summary | (unchanged) | Reinstall %3 on %1 (%2), keeping its accounts, files, apps and settings. |
| Accounts heading / body | — | Your accounts are kept / Everyone who uses this computer signs in as before, with the same password. The computer keeps its name, and stays managed or joined to a domain if it was. |
| Accounts row on the summary | — | Existing accounts and computer name are kept. |
| Language / location / keyboard rows | — | Kept as it is on this computer |
| Summary panel title / body | This erases %1 completely *(now with the real device)* | This reinstalls %1 on %2 / The system is replaced with a fresh copy. The accounts, files, apps and settings on that drive are kept, and other drives are left alone. |
| Finish title / lede | (unchanged) | %1 is reinstalled / Restart and sign in as before. |

## 10. `run-vm.sh`, for the loop somebody has to walk by hand

- **`--extra-disk-keep`**: the extra disk lives at `${IMG}.extra-disk.qcow2` and survives the
  run. When the file exists it is reused, with a log line that says to delete it to start over
  and that it keeps the size it was made with; when it does not, it is created from `--extra-disk
  SIZE`, and asking for it without a size dies. Without the flag nothing changes — the disk is in
  `$VMDIR` and thrown away.
- **A qcow2 as IMG.** The format is detected by its magic bytes (`QFI\xfb`) and `format=` follows
  it; `--disk-size` makes its overlay with `-F "$IMG_FORMAT"`. It dies if the kept extra disk and
  IMG resolve to the same file — two drives on one qcow2 is a corrupted qcow2.
- The header examples, the usage string and the `--extra-disk` comment are updated; *there is no
  `--writable` equivalent for it* becomes a description of the flag and of this loop:

```sh
run-vm.sh out/immos-<v>-installer.img --extra-disk 40G --extra-disk-keep   # 1. install
run-vm.sh out/immos-<v>-installer.img.extra-disk.qcow2 --writable          # 2. use it
run-vm.sh out/immos-<v>-installer.img --extra-disk-keep                    # 3. reinstall, keeping
run-vm.sh out/immos-<v>-installer.img.extra-disk.qcow2 --writable          # 4. check it
```

`docs/testing.md` gains both flags and a short *Reinstall and keep* walk-through.

## 11. Tests

A new section in `tests/test-installer.sh`, **6x. keeping what is on the disk (plan/33)**, plus
extensions to §3 and §5 and repairs to what this breaks.

| | |
|---|---|
| §3 and `test-common.sh`, the names | `emit_sfdisk_script 9.9.9` is still esp/root_9.9.9/var; `emit_sfdisk_script 9.9.9 live` is live_esp/live_root_9.9.9/live_var, and one slot has no `_empty`; `emit_install_sfdisk_script` always uses target names; `layout_names` dies on an unknown role |
| `test-profiles.sh` | `ROOT_PARTLABEL` is identical across profiles, as before; `IMG_ROOT_PARTLABEL` is `live_root_<v>` for the installer and equals `ROOT_PARTLABEL` for desktop and console; `fstab.in` renders `var`/`esp` for target and `live_var`/`live_esp` for live |
| §5, `inspect` against fixtures | heredoc `sfdisk --dump` texts, no sfdisk needed: keep with `root_0.3.0` + `_empty`; keep with two `root_*`, `installed=` the higher; nvme-style `p` nodes; `none` with no var; refuse for `dos`, three partitions, a wrong type, a small ESP and a small slot. `inspect` is defined only in `layout.sh` |
| …the medium | `disk.conf` and `disksetup.conf` render the same `layoutHelper`; stage 40's helper probe runs `inspect` too |
| …the job | the keep path has no `write_table(` and no whole-device `wipefs`; `_empty` is relabelled before the slot; `e2fsck -p` runs and `overlay/etc/upper` is checked; the mkfs counts are still one and one; still no GUID in `main.py` |
| …the jobs that stand down | `localesetup`, `keyboardsetup`, `imageidentity` and `accountsetup` read `diskKeepData` in `run()`; `imagedeploy` skips the template under it |
| …`removeuser` | on the forbidden list, with the reason; `removeuser.conf.in` absent; `accountsetup`'s `userdel` is outside keep only. The "accountsetup before removeuser" ordering assertion is replaced, and `test-domain.sh`'s comment that names it is corrected |
| …the pages | `disk` publishes `diskKeepData` and runs `inspect`; `accounts` reads `diskKeepData` in `onActivate()` and publishes `"kept"`; `review` reads `diskDevice` and never `"device"`, and reads `diskKeepData`; `done` and the three rows read `diskKeepData` |

The generic checks — §6i's qmllint, every `Q_PROPERTY` notifying something emitted, every
`disk.<name>` binding resolving, no `qsTr()`, and `check-translations.py` — must pass untouched.

**Stage 40**, after the existing `_layout_probe`: `truncate -s 64G` a scratch file, `sfdisk` the
probe into it, `sfdisk --dump` it into `"$DISK_LAYOUT_DST" inspect`, and require `verdict=keep` and
`installed=$VERSION`. That is the helper's keep path run once against a real table on the medium,
for the reason the existing probe gives: everything after it is a stranger's hardware.

## 12. Locks, translations and the build

- The overlay edits move `portage_config_hash`. The fix is the header, not a relock: put the new
  hash — `REPO=$PWD; source scripts/lib/common.sh; portage_config_hash` — into the
  `# PORTAGE_CONFIG_HASH:` line of `config/portage/lock/{console,desktop,installer}.lock`, then run
  `tests/test-pin-policy.sh`.
- `scripts/update-translations.sh`, then every new `unfinished` entry filled for de, es, fr, it,
  ja, pt_BR, ru and zh_CN. Changed sources go `vanished` and must not linger. Every catalogue is
  complete today, with nothing unfinished, and stays that way.
- Stage 30 rebuilds the edited overlay packages by itself. The desktop payload needs no rebuild:
  the target labels are unchanged and `VERSION` stays where it is.

## 13. Known limits

- **An older medium over a newer install is allowed.** It is the same risk as a rollback onto a
  `/var` a newer version wrote.
- **New pre-installed apps are not added.** Apps that ship in a newer medium's template do not
  reach a kept store. Online, `appsetup` updates the existing apps and installs the chosen ones.
- **Kept `/etc` changes shadow the new image's defaults**, exactly as they do after an update
  ([plan/01](01-architecture.md)).
- **Keeping needs this build's geometry.** The disk's ESP and both slots must be at least this
  build's `ESP_SIZE_MIB` and `ROOT_SLOT_SIZE_MIB`; a disk laid out smaller shows the row disabled.
- **An enrolment made earlier in the session is released** when keeping is chosen, by the path
  that already releases it when managed mode is left.
- **The encryption row is hidden on a disk that offers keeping** (§3).
- **Sticks made before this document still have the clash** §2 removes. Only a medium built after
  it boots unambiguously next to an installed disk.
- **Built, not yet driven**, until the §10 loop has been walked on a VM: install; boot the
  installed disk, add a file and a Flatpak, change the time zone and keyboard, note the hostname
  and machine-id; reinstall keeping, checking that `findmnt / /var` names the stick; boot again and
  find all of it unchanged, with `root_<v>` on p2 and `_empty` on p3; then reinstall once more
  with the box unticked. The disk page is checked at 1024×640 in English and German with two
  disks listed.

## Changes to other documents

- **[plan/16](16-installer.md)** — §5.3's module map: `removeuser` is folded into `accountsetup`.
  §10 1b is **ANSWERED by plan/33 §2**.
- **[plan/24](24-installer-disk-page.md)** — §1 and §8 point here for the keep row and the keep
  path.
- **`config/calamares/README.md`** — the disposition table's `removeuser` row; a new section,
  *Reinstalling and keeping files*; the "Remove the medium" known limit rewritten, because the
  labels no longer clash and the reminder stays only because firmware may boot the stick again.
- **`config/calamares/modules/done.conf.in`** — its comment on the label ambiguity, rewritten the
  same way.
- **`config/portage/overlay/README.md`** — if a module's description changes.
- **`docs/testing.md`** — §10's flags and loop.
