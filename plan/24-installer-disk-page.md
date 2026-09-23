# 24 — The disk gets a page of its own

[plan/16 §5.3](16-installer.md) called for "a small disk-select module … whole-disk erase only, so
the UI is a disk picker, not a partition editor", and then didn't write one. Everything in that
sentence turned out to be reachable from stock `partition` by configuration —
`allowManualPartitioning: false`, `initialPartitioningChoice: none`, and a `partitionLayout` that
fixed the names, the GPT type GUIDs and the sizes — so the module was kept and reconfigured, and
the reasoning was written down in `modules/partition.conf`: writing a C++ module would have cost
the ~80 translations, the device enumeration, the preview widget and the KPMcore job plumbing, to
arrive at the same screen.

It did not arrive at the same screen. What `allowManualPartitioning: false` produces is a partition
editor with most of its controls taken away: a device combo box, an "Erase disk" radio button that
is the only choice offered, and a before/after strip drawn in partition colours, all of it labelled
in upstream's words for an installer that offers manual partitioning, side-by-side installs and
filesystem choices. This distro has none of those. The page asks one question — **which disk** —
and every other thing on it is scar tissue from a question it is not asking.

This document replaces it with `disk`, the fourth compiled view module, and `disksetup`, the fifth
python job. The two halves are one replacement: a Calamares view step owns its `jobs()`, so
removing the page removes the partitioner with it.

## 1. What it looks like

Four states, at the 710×536 a view module actually gets. A fifth — a disk that already holds an
install — is [plan/33](33-reinstall-keeping-files.md) §3's, which draws over this section's
encryption row rather than adding a sixth block.

The mockups below predate the confirmation dialog (plan/26), the design-system repaint (plan/28)
and the layout tightening (plan/30, plan/31); they are kept as the record of the shape this page
started from, not as what it currently draws.

```
 ┌───────────────────────────────────────────────────────┐  nothing chosen yet
 │ Where should Immutable OS be installed?    ⟳ Check again│
 │ Everything on the disk you choose will be erased.      │
 │ ──────────────────────────────────────────────────────│
 │ ○ 🖴 Samsung SSD 990 PRO 1TB      /dev/nvme0n1   1.0 TB│
 │      3 partitions — EFI, Windows (NTFS, 420 GB), …    │
 │ ○ 🖴 WDC WD20EZBX-00AYRA0         /dev/sda      2.0 TB │
 │      1 partition — Backup (ext4, 1.9 TB)              │
 │ ⊘ 🖫 SanDisk Ultra USB 3.0        /dev/sdc       31 GB │
 │      ⊘ Immutable OS is running from this disk         │
 │ ⊘ 🖫 Kingston DataTraveler        /dev/sdd       15 GB │
 │      ⊘ Too small for an installation                  │
 └───────────────────────────────────────────────────────┘
        ← Back            Next →  (disabled)

 ┌───────────────────────────────────────────────────────┐  chosen and confirmed
 │ …                                                     │
 │ ●  Samsung SSD 990 PRO 1TB       /dev/nvme0n1  1.0 TB │  ← selected
 │ ──────────────────────────────────────────────────────│
 │ The disk will be set up like this                     │
 │ ▓▒░████████████████████████████████████████████████████│
 │ ■ Boot 1.1 GB  ■ System 6.4 GB  ■ Reserved for updates│
 │ 6.4 GB  ■ Your files 986 GB                           │
 │ ☑ Erase this disk and everything on it                │
 │    3 partitions will be deleted, including Windows    │
 │    (NTFS, 420 GB).                                    │
 │ ──────────────────────────────────────────────────────│
 │ 🔒 Encrypt this disk   Not yet available          (○ )│
 └───────────────────────────────────────────────────────┘
        ← Back            Next →

 ┌───────────────────────────────────────────────────────┐  one disk in the machine
 │ This computer has one disk.                           │
 │ Immutable OS will be installed on it, and everything  │
 │ on it now will be erased.                             │
 │ ● Samsung SSD 990 PRO 1TB … (selected for the user)   │
 │ ☐ Erase this disk and everything on it   ← still unticked
 └───────────────────────────────────────────────────────┘

 ┌───────────────────────────────────────────────────────┐  nothing installable
 │ No disk can be used for the installation.             │
 │ Immutable OS needs a disk of at least 32 GB that it   │
 │ is not itself running from.                           │
 │ ⚠ Plug in a disk of at least 32 GB and choose Check   │
 │   again. These are the disks this computer has now:   │
 │ ⊘ SanDisk Ultra USB 3.0 … running from this disk      │
 └───────────────────────────────────────────────────────┘
        ← Back            Next →  (disabled)
```

### 1a. The five things in that sketch that are decisions

**Every disk is a row, including the ones that cannot be used.** "Why is my disk not in this list?"
is a question a picker should answer on screen rather than through a support call — and one of the
answers, *because the installer is running from it*, is the single most important sentence on the
page. Greyed rows keep the same grammar as live ones: same icon, same size column, and the second
line carries the reason instead of the contents.

**The list scrolls and the consequences do not.** Everything that follows from choosing a disk —
the plan, what will be lost, and the checkbox — is pinned below the list. The alternative was
drawn and rejected: folding the panel into the selected row reads better and behaves worse, because
the row grows by ~160px, every row under it moves, and on a page whose one risk is clicking the
wrong disk the list must not move under the cursor.

**The bar is to scale.** The ESP and both root slots really are about 1.4% of a 1 TB disk, and the
bar says so; the honest version is also the reassuring one, because what it shows is that almost
all of the disk stays the user's. Segments have a floor of a few pixels so that a small partition
reads as small rather than as missing, and the sizes are written out underneath where they can be
read. "Your files" is `var` and gets the positive colour: it is the only segment that belongs to
the person reading the page, and it is nearly all of the disk.

**The sub-line names the loss.** *3 partitions will be deleted, including Windows (NTFS, 420 GB).*
It is built from what the row already read, and it is the sentence somebody needs in front of them
before they tick a box. When the target is removable it gains one more: *This is a removable disk.*
— one line, not a second checkbox. Installing onto an external SSD is a real thing to want;
installing onto the stick next to the one you booted from is not, and the difference is worth a
sentence rather than a wall.

**Selecting is a convenience; confirming is not.** With one disk in the machine the page selects it
— there is nothing to choose — and leaves the box unticked, because that tick is the only
deliberate act on the page. Next needs both.

## 2. Why the stock module had to go entirely

A Calamares view step owns its `jobs()`. `PartitionViewStep` draws the page **and** produces the
KPMcore jobs that write the disk, so there is no way to replace one half: the moment `partition`
leaves the `show:` sequence it leaves `exec:` too, and something of ours has to write the GPT.

That is the whole reason this change is two modules rather than one, and it is the same shape as
plan/21's `accounts` + `accountsetup`: the page is C++ because Calamares accepts only C++ QtPlugin
views (`ModuleFactory.cpp:53`), and the work is a python job because a job *can* be a script and
there is no reason to compile one against Calamares' ABI.

What it costs is the thing `modules/partition.conf` warned it would cost — device enumeration, and
a preview widget — and both came in smaller than the estimate, because this installer needs far
less of either than a general-purpose one. Enumeration is `/sys/block` plus one `lsblk --json` for
the second line of each row; the preview is four labelled segments of a bar. What it does **not**
cost is the KPMcore job plumbing, because the job it replaces does one `sfdisk`, one `mkfs.vfat`
and one `mkfs.ext4`. The ~80 translations are a real cost and are not paid yet — see §10.

## 3. Gigabytes, decimally, on both pages

The page speaks **decimal GB**: `1.0 TB`, `986 GB`, `32 GB`. A disk's size is the number printed on
the disk, and the user's job on this page is to recognise their own hardware in a list of three.

That collided with a deliberate decision the greeting page had already made. `Requirements.cpp`
formatted IEC on purpose, and said why: `requiredStorage` was written in GiB, so a page reporting
"34.4 GB needed" for a config that says 32.0 would send whoever set it looking for a bug that is
not there. Both halves of that are now fixed rather than one:

- `requiredStorage` is **decimal GB**, and is not a number written in `greeting.conf` at all. It is
  `build.conf`'s `MIN_INSTALL_DISK_GB`, rendered.
- `modules/disk.conf`'s `minimumDiskSize` is rendered from the **same** value, and so is the job's
  own re-check.
- The greeting page formats disk sizes SI and memory sizes IEC, which is not an inconsistency:
  disks are sold decimal and RAM really is sold in binary multiples, and an installer that picked
  one unit for both would be wrong about one of them.

The requirement drops by 7% as a side effect — 32 GiB was 34.4 GB; 32 GB is 29.8 GiB — and
`validate_config()` now does the arithmetic that used to live in a comment: the number has to cover
the ESP, both root slots, the two alignment megabytes and at least 4 GiB of `/var`.

One number, three consumers: the page that decides whether Next may be pressed, the page that
decides which rows are selectable, and the job that refuses a disk it cannot lay out. Two of those
used to be two numbers in two units, and the failure that pairing produces has no error message —
an installer that says *this computer can install* and then offers nothing to install onto.

## 4. One description of the layout

`compute_layout()` and `emit_sfdisk_script()` move out of `lib/common.sh` into **`lib/layout.sh`**,
unchanged. `common.sh` sources it, so stage 60 builds the factory `.img` exactly as before. Stage
40 installs the same file, **byte for byte**, onto the installer medium as
`/usr/libexec/<id>-disk-layout`, and `disksetup` runs it.

The file is a library when sourced and a CLI when executed, which is one `BASH_SOURCE` guard at the
bottom. It gains one function, `emit_install_sfdisk_script`, which is the installer's call: the
factory image is built to a size the pipeline chose, and an installed machine is built to the size
of a disk somebody owns, so `var` takes the remainder rather than a number from `build.conf`.

**This is the change that deletes a class of bug.** The installed machine's partitions came from a
`partitionLayout:` block in `modules/partition.conf` and the factory image's came from
`emit_sfdisk_script()`: two descriptions of one layout, 300 lines apart in two languages.
`tests/test-installer.sh` existed largely to compare them label by label, GUID by GUID and size by
size — a test that can only ever catch the drift it was taught to look for, and plan/16 §3.4 is
what makes drift fatal, because a machine whose partition labels or types differ from the image's
is one `systemd-sysupdate` stops recognising. One file cannot disagree with itself.

What the test asserts instead is that the arrangement is still that arrangement: `layout.sh` is the
only definition of those functions, `common.sh` sources rather than redefines them, the file reaches
for nothing the medium does not have, stage 40 installs it verbatim and executable, `disksetup.conf`
names exactly that path, and the job's `main.py` carries no GPT type GUID of its own. The way this
comes apart is somebody re-introducing a second copy, which would look like a perfectly reasonable
patch.

## 5. Why it is called `disk`

`calamares_add_plugin` installs a viewmodule into `<libdir>/calamares/modules/<name>/`, so a plugin
called `partition` would collide file-for-file with `app-admin/calamares`' own and Portage would
block the merge. Worse than a blocked merge, again: `ModuleManager::doInit()` walks `modules-search`
in order and keeps the **first** `module.desc` it finds for a given name, silently — so two modules
named `partition` would resolve by the order of a list in `settings.conf`, with no log line saying
which one won.

The directory, the `module.desc` name and the `settings.conf` entry are all `disk`;
`DiskViewStep::prettyName()` returns `tr( "Disk" )`. The sidebar names what the user chooses on each
page, and on this one they choose a disk — there is no partition editor behind it and no partition
to name.

## 6. The exclusion that protects data

Until now this was free. `PartUtils::getDevices( WritableOnly )` drops any device holding a
partition mounted at `/` (`core/DeviceList.cpp:178`), so on this medium the live USB disappeared
before the page was drawn, and `config/calamares/README.md` recorded it as a known limit to verify
on the first hardware run — *the one failure in this installer that destroys data*.

We do not run that code any more. The rule is ours, and it is implemented **three times**:

| where | why it is separate |
|---|---|
| `DiskConfig::liveMediumDisk()` | so the medium cannot be selected |
| `disksetup`'s `check_target()` | so a stale or wrong GlobalStorage value cannot be acted on. The page's answer arrives here as a string, and a job that erases a disk should not take a string's word for it |
| `Requirements::largestInstallableDiskB()` | the greeting page already had its own, so "is there a disk big enough" and "which disks may I use" cannot answer differently |

They are separate because the three live in different plugins and none installs a header the others
could include. All three make the same test the same way, and the test asserts all three still
exist: a partition of disk *D* is always a directory **inside** `/sys/block/D`, which is what makes
`nvme0n1p3` resolve to `nvme0n1` with no rule about trailing digits. The string-surgery version
("chop the digits off the end") gives `nvme0n1p`, matches nothing, and puts the medium back in the
picker — on NVMe only.

What changed for the user is that the medium is now **visible**, greyed, saying why. It was
invisible before, which is safe and unexplained; this is safe and explained.

The job adds two things the page cannot: it releases the target (a Plasma session automounts what
it finds, and `sfdisk` will rewrite a table underneath a mounted partition and leave the kernel
refusing to re-read it), and it `wipefs`es before writing, because `sfdisk` writes a GPT and does
not remove a stale MBR or a filesystem superblock sitting where the new ESP will be.

## 7. Encryption, drawn and disabled

The row exists, greyed, saying *Not yet available*. `DiskConfig::encryptionAvailable()` returns a
literal `false`, nothing in the module or the job mentions `cryptsetup`, and the test asserts both.

Drawn rather than hidden, because hiding it means the first person to ask about encryption has to
ask whether it was forgotten. Designed now rather than later, because the panel has to have room
for it: turning it on adds two radio buttons and a sentence to a panel that already fits, and no
new page.

What it will encrypt, when it is built, is `var` — the root image is read-only and identical on
every machine, and the ESP cannot be encrypted at all, so everything private is on one partition.
There is one collision worth recording now: the boot splash has no text renderer at all, because
every glyph ships pre-rendered as pixels ([plan/14](14-boot-splash-kms.md)), so a passphrase prompt
has nowhere to draw. That is a boot-path change, not a page change, and it is the reason this row
is disabled rather than merely unbuilt. `GlobalStorage` carries `diskEncrypt: false` from the page
today, written rather than omitted so the key's absence never has to mean two things.

## 8. What moves

| | |
|---|---|
| `scripts/lib/layout.sh` | **new.** `compute_layout`, `emit_sfdisk_script` (both moved verbatim), the three GPT type GUIDs, plus `emit_install_sfdisk_script` and a CLI |
| `scripts/lib/common.sh` | sources it; `validate_config` gains `MIN_INSTALL_DISK_GB` and the arithmetic that checks it against the layout |
| `config/build.conf` | **new key** `MIN_INSTALL_DISK_GB="32"` |
| `config/portage/overlay/distro-base/distro-calamares-disk/` | **new.** Ebuild + `files/`: `DiskViewStep`, `DiskConfig`, `DiskModel`, `qml/Disk.qml`, `disk.conf` |
| `config/calamares/local-modules/disksetup/` | **new.** `module.desc` + `main.py` |
| `config/calamares/modules/disk.conf.in` | **new.** Three numbers: the minimum, and the two the bar is drawn from |
| `config/calamares/modules/disksetup.conf.in` | **new.** The helper's path, the geometry, the version and the root PARTLABEL it must produce |
| `config/calamares/modules/partition.conf.in` | **deleted**, with the module it configured |
| `config/calamares/modules/greeting.conf.in` | `requiredStorage` is rendered from `MIN_INSTALL_DISK_GB` and is decimal GB |
| `…/distro-calamares-greeting/files/Requirements.{h,cpp}` | `humanBytes()` splits into `diskBytes()` (SI) and `memoryBytes()` (IEC); `m_requiredStorageGiB` → `m_requiredStorageGB` |
| `config/calamares/settings.conf.in` | `disk` replaces `partition` in `show:`; `disksetup` replaces it in `exec:`, first |
| `config/portage/sets/installer` | adds `distro-base/distro-calamares-disk`. The set's asserted count goes 4 → 5 |
| `scripts/stages/40-configure.sh` | asserts the `disk` module is installed; installs `layout.sh` and checks it verbatim, executable, parsing and producing all four partition names; exports two new tokens; the payload verify block reads `disksetup.conf` instead of `partition.conf`, and asserts no `partition.conf` survives |
| `scripts/lib/check-translations.py`, `scripts/update-translations.sh` | the disk module joins the source list |
| `config/calamares/README.md`, `config/portage/overlay/README.md` | the module maps gain their rows; the live-medium known limit is rewritten, because it is ours now |

**The keep path.** [plan/33](33-reinstall-keeping-files.md) adds a fourth answer to "what does
this disk get" — kept rather than erased — on top of everything above: `DiskModel`/`DiskConfig`
gain the keep verdict and the checkbox, `disksetup` gains a second path through `run()` that
never calls `write_table()`, and `scripts/lib/layout.sh` gains `inspect`, the one place the GPT
type GUIDs are compared against an EXISTING disk rather than written to a new one. Nothing in
this section's table stopped being true; plan/33 is what runs after it.

The lock moves for one package, and the config hash for all of them:

```sh
scripts/relock.sh distro-base/distro-calamares-disk --profile installer
scripts/relock.sh --restamp     # the other profiles: MIN_INSTALL_DISK_GB is invisible to portage
```

## 9. Tests

| | |
|---|---|
| `test-installer.sh` §5, the layout | `layout.sh` is the only definition of the three functions; `common.sh` sources it; it reaches for no `$REPO`, `load_config` or `BUILD_PROFILE`; its CLI is guarded by `BASH_SOURCE`. The installed layout has four partitions, both root slots, the pipeline's GPT types, the build's slot size, a `var` sized to the remainder, and a total that is **exactly** the disk it was given. A disk too small is refused, not truncated |
| …the medium's copy | stage 40 installs it verbatim (`cmp`), executable, at the path `disksetup.conf` names; the job carries no GPT GUID of its own; no `partition.conf` is rendered and no `partition.conf.in` remains |
| …one minimum | `greeting.conf`, `disk.conf` and `disksetup.conf` all render `MIN_INSTALL_DISK_GB`; `disk.conf`'s bar geometry is the build's |
| …the units | the greeting page formats disks SI and memory IEC; its requirement is read as GB; the disk page uses the same SI formatter |
| §6, the sequence | `disk` in `show:` before `accounts`; `disksetup` **first** in `exec:`; the stock `partition` module is on the forbidden list |
| §6e, the data-destroying one | all three copies of the live-medium exclusion exist, and all three test containment rather than chopping digits; the job refuses an unconfirmed target, a target that is not a whole disk, and the medium by name |
| …the job | it releases mounts and swap and stops rather than continuing when it cannot; it `wipefs`es first and waits for udev; exactly one `mkfs.ext4` and one `mkfs.vfat`, neither on a root slot; the filesystem labels match stage 60's; it publishes `partitions` with the keys `imagedeploy` and `imagebootloader` read |
| …the page | Next needs a disk **and** the tick; changing the disk clears the tick; a blocked row is refused as a selection; the four-line QML/C++ selection wiring is the language page's; blocked rows are disabled, not filtered; the encryption row exists, is off, and nothing implements it; no `QQuickStyle::setStyle`; the engine retranslates; `DiskModel` is its own file; every `disk.<name>` binding resolves and every `Q_PROPERTY` is CONSTANT or notifies something that is emitted |
| `test-managed.sh` | the overlay renders exactly **five** ebuilds |

The things that can only be seen by running the installer are unchanged from plan/22 and plan/23
and blocked on the same gap: stage 70 cannot drive Calamares unattended. Everything above closes a
failure that compiles.

## 10. Known limits

- **The page is English in every language.** Its `qsTr()` strings are not in
  `branding/installer/lang/*.ts` yet, which is the same position the accounts page has been in since
  plan/21 — `check-translations.py` proves that every string *in* a catalogue matches the code, and
  says nothing about strings in the code that are in no catalogue. `scripts/update-translations.sh`
  now scans this module; somebody has to run it and fill in the entries.
- **It has been built, not yet driven.** The module compiles, links and installs, and a medium
  carrying it builds through stage 60. Nobody has clicked the page: no VM boot, no hardware run.
  The first build did find what a first build finds — see §11, which is the whole of what it
  found and is fixed.
- **`lsblk` is trusted for the second line and nothing else.** If it is missing or its JSON changes
  shape, rows read "Contents unknown" and the page still works — enumeration, sizes and the medium
  exclusion are all sysfs. That is the right layering and it does mean the most useful line on each
  row is the one with a dependency.
- **The partition-number rule is written twice.** `partition_node()` in the job and
  `esp_device()` in `imagebootloader` split the same names in opposite directions, in two
  languages. Merging them would mean a python module importing from a shell script or the reverse.
- **A disk that changes size between the page and the job is not handled specially.** The job
  re-reads sysfs and refuses a disk that has become too small, but a USB disk pulled between the
  checkbox and the exec phase produces a failed install rather than a graceful one.

## 11. The number that was never delivered

The first build of this page shipped with four of its five numbers set to zero, and the medium
reported it plainly: the greeting announced **"This computer can install"** on a machine with no
disk attached at all, and the disk page asked the user to *"plug in a disk of at least 0 bytes"*.

The cause is upstream, in two files that do not agree about what an integer is:

- `libcalamares/utils/Yaml.cpp` reads every unquoted integer scalar into a QVariant holding a
  **qlonglong**.
- `libcalamares/utils/Variant.cpp`'s `getDouble()` accepts **`Int` or `Double`** and nothing else.
  A `LongLong` matches neither, so it falls through and returns the caller's default.

So whether a number in a Calamares configuration file is read at all depends on whether somebody
wrote `.0` after it:

    requiredStorage: 32.0   ->  Double    ->  32.0
    requiredStorage: 32     ->  LongLong  ->  the default, silently

§3 moved these keys off hand-written literals and onto `build.conf`, which holds
`MIN_INSTALL_DISK_GB="32"` and `ESP_SIZE_MIB="1024"` — integers, because that is what they are.
Rendering them dropped the `.0` that had been carrying them, and with it:

| key | read as | consequence |
|---|---|---|
| `requiredStorage` | 0 | the greeting **deletes its own storage check** and passes any machine |
| `minimumDiskSize` | 0 | every disk is selectable, and the empty state says "at least 0 bytes" |
| `espSizeMiB` | 0 | the plan bar draws nothing, for every disk |
| `rootSlotSizeMiB` | 0 | as above |
| `requiredRam` | 4.0 | correct, and only because `4.0` was still spelled with a decimal point |

Both pages' zero-guards fired correctly and logged to the Calamares log; nobody was reading it.

**The fix is on the reader, not the file.** Both plugins define a file-static `configNumber()` over
`QVariant::toDouble()`, which accepts every numeric type there is, and refuses `Bool` rather than
converting it — YAML reads `on` and `true` as booleans, and a page that treats
`requiredStorage: true` as a one-gigabyte minimum is worse than one that falls back to its default.
It is written twice for the same reason `liveMediumDisk()` is (§6): two plugins, neither installing
a header the other could include. Padding the templates with `.0` was the alternative and is the
worse fix — it leaves the trap armed for the next key anybody adds.

**What this says about the tests.** Nothing offline could have caught it. `build.conf` was right,
the template was right, the rendered file on the medium was right, and `test-installer.sh` asserted
all three agreed on `32`. The value was correct at every point the build could see and was discarded
after the last of them. The assertion that replaces those is on the reader: both pages parse their
own numbers, neither may call `Calamares::getDouble`, and the count of `configNumber` call sites is
pinned at five so a sixth key cannot quietly go back to the upstream function.

The `disksetup` job was never affected — Python's `int()` and `float()` coerce whatever the
bindings hand over. For one build the job would have partitioned a disk correctly that the pages in
front of it had already lied about.

## Changes to other documents

- **[plan/16](16-installer.md) §5.3** — the module map's `partition` row read *Keep and
  reconfigure*; it becomes *Replaced by `disk` + `disksetup`*. §8's Phase A note about three
  departures loses the one about `partition` being kept.
- **[plan/20](20-installer-slimming.md) §4** — the note that `ROOT_SLOT_SIZE_MIB` is substituted
  into `modules/partition.conf.in` now points at `modules/disk.conf.in` and
  `modules/disksetup.conf.in`.
- **`config/calamares/README.md`** — the disposition table's `partition` row, two new rows in "Our
  modules", and the live-medium known limit, which is no longer a statement about Calamares.
- **`config/portage/overlay/README.md`** — the package table and the tree listing gain a row.
