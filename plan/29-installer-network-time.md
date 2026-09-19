# 29 — The clock the installer could show and could not set

The location page (plan/28 §6) draws a clock at 44px in the chosen zone, and calls it "the one
control on this installer whose effect can be checked by looking at it". That was true and it was
only half a design: a page that shows you the time and cannot correct it is a page that shows you
a problem. If the machine's clock is wrong — a board with a dead RTC battery, a dual-boot machine
whose other operating system writes local time into it, a machine that has never been on a
network — the installer displayed the wrong time in a large mono face and offered nothing.

`LocationConfig.h` said so, in the note listing the four controls the design hand-off draws and
this page does not:

> *"Automatic time and the 24-hour clock are settings on the INSTALLED system that nothing in this
> pipeline writes — no timesyncd drop-in, no Plasma locale config. A switch with no wiring behind
> it is worse than no switch: it is a promise the first boot breaks."*

That is the right test and this plan passes it. All three ends now exist, so the switch is built.

## What the page gains

**A checkbox — "Set the time automatically over the network" — ticked when the page opens.** It is
not a preference that gets written down somewhere and applied later: checking it runs
`timedatectl set-ntp true` on the machine the installer is running on, and then *watches*
`NTPSynchronized` until a server has actually answered. Under it, a status line that says which
server set the clock, or that none did.

The watching is the part worth arguing for. Asking systemd to enable NTP and then announcing "the
clock is set from the network" is a claim about a server that has not been contacted yet. On a
machine with no route out, that announcement is false and the user has no way to know — until a
TLS handshake fails three screens later with an error about certificates.

**A "Set date and time…" button**, disabled while the box is ticked, opening a dialog with a date
and a time field. Confirming runs `timedatectl set-time`, which systemd also writes through to the
RTC — so the machine this medium is about to install onto starts from the clock the user just
corrected.

Two details that are not obvious and are both load-bearing:

* **The typed time is read in the chosen zone and written in the machine's.** The page shows a
  clock in the zone the user picked; a correction is a correction to *that* clock. But
  `timedatectl set-time` reads its argument in the zone `/etc/localtime` names, which on this
  medium is UTC and deliberately stays UTC (`modules/location.conf`). Handing it the typed string
  unconverted would set the machine hours wrong in exactly the way that looks like it worked.
* **The two fields take one fixed format, not the locale's.** Everything else on this page is
  *read*, and a reader is best served by their own conventions — the clock and the date under it
  go through `QLocale`. These two are *typed*, and a typed date in a locale's short form carries an
  ambiguity the field cannot ask about: 03/04/2026 is two different days on two sides of an ocean.
  So the dialog shows and takes `2026-09-18` and `21:30`, and the hint under each field is a worked
  example rather than a format string.

The dialog is a `QQC2.Popup` with everything drawn from the design system, not a
`Kirigami.PromptDialog`. The disk page's erase confirmation is one of those and is the last
unbranded surface in this installer; copying it here would have made two.

## What the installed system gains

This is the half that makes the checkbox a question worth asking rather than a convenience on a
USB stick. The page publishes `locationNetworkTime` — **not** an upstream key name, unlike
`locationRegion` and `locationZone` beside it, because upstream's locale module has no notion of
network time and there is no published contract to honour.

`localesetup` reads it:

* **Ticked** — nothing to do. `systemd-timesyncd.service` is already enabled in the vendor preset
  (`50-distro.preset.in`), so the image already is what the box promises. A job that re-enabled an
  enabled unit would be writing a symlink that is already there to make a log line look busy.
* **Unticked** — the unit is **masked** in the target, and the preset's `sysinit.target.wants`
  symlink removed.

A mask rather than a disable, and the difference matters on an image whose `/etc` is an overlay
over a read-only lower (plan/16 §5.2). Deleting the `.wants` symlink is a whiteout in the upper and
is undone by the next `systemctl preset-all` — a thing an administrator or a later update can
legitimately run — which would quietly switch network time back on. A mask is a statement systemd
will not overrule, and `systemctl unmask systemd-timesyncd` is how somebody changes their mind
later, in one obvious command. The `.wants` whiteout goes with it anyway, so the installed system
does not carry a symlink pointing at a masked unit: that combination works, and it reads as a
mistake to the next person looking at the machine.

## Which servers: `FallbackNTP`, not `NTP`

`build.conf` gains `NTP_SERVERS`, space-separated, rendered by stage 40 into
`/etc/systemd/timesyncd.conf.d/05-<id>-ntp.conf` on **every** profile.

The key is `FallbackNTP=` and that is the whole of the design. systemd-timesyncd asks, in order:
the servers DHCP handed out, then `NTP=`, then `FallbackNTP=`. `NTP=` already has an owner —
`<id>-domain join` writes `10-domain.conf` naming the domain controller, because Kerberos refuses a
ticket from a machine more than five minutes out (plan/18 §5.1). So a machine on a network that
runs its own time service uses it, a joined machine uses its DC, and a laptop on a café's wifi uses
the list from `build.conf`. Writing `NTP=` here instead would have put a build-time default ahead
of every one of those, on every machine this image ever becomes. Stage 40 asserts the rendered file
does not set `NTP=`, because that mistake has no symptom until somebody's domain login fails.

The `05-` prefix is the other half: drop-ins are read in lexical order and a later file wins a key
it sets, so this one is read before `10-domain.conf` and claims only the key nothing else claims.

Both the medium and the installed image ship it. If the medium synced against a different list than
the machine it creates, the check the user just watched succeed would say nothing about the machine
they end up with.

**An empty `NTP_SERVERS` is meaningful**: stage 40 then deletes the rendered file rather than
shipping `FallbackNTP=`, because an empty assignment *clears* systemd's compiled-in default. "The
knob is unset" and "there are no fallback time servers" must not be the same image. That is also
why `common.sh` defaults it to empty rather than to a list: a `build.conf` written before this knob
existed should not quietly acquire different time servers than the systemd it ships.

## Files

| area | paths |
|---|---|
| build knob | `config/build.conf`, `scripts/lib/common.sh` (default + validation) |
| the drop-in | `config/rootfs/etc/systemd/timesyncd.conf.d/05-distro-ntp.conf.in` |
| build | `scripts/stages/40-configure.sh` (export, the empty-knob deletion, three assertions) |
| the page | `distro-calamares-location/files/LocationConfig.{h,cpp}`, `LocationViewStep.{h,cpp}`, `qml/Location.qml`, `CMakeLists.txt` (Button.qml, Field.qml) |
| configuration | `config/calamares/modules/location.conf`, the packaged `files/location.conf` |
| the job | `config/calamares/local-modules/localesetup/main.py` |
| tests | `tests/test-installer.sh`, `tests/run-tests.sh` (the new export) |
| locks | `config/portage/lock/*.lock` — restamped; `NTP_SERVERS` is inside `portage_config_hash` |

## Verification

1. `bash tests/run-tests.sh` — offline. Section 6r covers the knob, the drop-in's key and prefix,
   the three page controls, the published key and the job's mask.
2. `./build.sh --profile installer`, or stages 10→60 directly against the existing builder image.
3. **Look at it, and look at it in the one state a test cannot reach.** Boot the medium in a VM and
   check: the box ticked and a server named under it; unticking it and setting a time by hand, with
   the clock above changing to what was typed; and the same page with the VM's network detached,
   where the status line has to end at "No time server answered" rather than at "Checking…".
