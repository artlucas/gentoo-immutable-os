# 25 — The applications page, and the download it decides

The four pages before this one each replaced something — `welcome` twice over, `users`, `partition`
— and the shape of every one of those replacements was "the stock module's words on a page that
asks a question this distro does not". This page replaces nothing. No stock Calamares module asks
which applications to install, because no mutable-distro installer needs to: they have a package
manager, and the question happens after the install, one app at a time.

This distro is Flatpak-first and immutable ([plan/03](03-package-set.md)), which puts the question
inside the installer's window for the first time: the image ships five applications
(Firefox, Ark, Kwrite, Okular, Gwenview) pinned to Flathub commits in `config/flatpak/apps.lock`,
and the one moment those pins can be lifted — and the one moment a Thunderbird or a Krita can be
added without the user meeting a package manager — is while the installer is already standing
there with the target mounted.

So: `apps`, the fifth compiled view module, and `appsetup`, the sixth python job. One question,
three answers — **the typical set**, **nothing extra**, or **a chosen list** — and one promise
either way: online, everything flatpak in the target ends up at the latest version Flathub has.

The typical set is Thunderbird, VLC, LibreOffice, Krita, KRDC and Kate — none of them in the base
image, none of them in `apps.lock`, all of them real Flathub refs. Custom is a checkbox list of
exactly those six, opening with every box ticked, so "custom" starts where "typical" ends and the
only work it adds is crossing things off.

## 1. The offline rule, which is the whole design

An install with no network at all is a supported, first-class path — that sentence is
[greeting.conf](../config/calamares/modules/greeting.conf.in)'s `required:` list, [plan/16 §5.1]'s
payload, and stage 90's entire reason for existing. A page that *required* connectivity to answer
would gate that path; a page that *offered* a download it could not perform would lie about it.

So offline is not an error state on this page. It is the one state that changes what the page can
ask:

- the two choices that need a connection are **disabled, not hidden** — the disk page's
  encryption-row rule (plan/24 §7): the first person to ask why there is no application picker
  should be answered by the page, not by a support article;
- C++ **forces** the mode to *nothing extra* — the QML cannot ask for a refusal, so the refusal is
  never asked for;
- the note that replaces the choices' enablement says what to do **later** ("add applications from
  Discover"), not what went wrong;
- Next stays lit. *Nothing extra* is an answer; the payload's applications are already on the disk,
  and the install is complete without this page doing anything.

The verdict is re-asked **every time the page is entered** (`onActivate`), and once more by the
"Check again" button. The greeting page's check ran once, before the first page was drawn; the
network coming up during the keyboard page is exactly the case it cannot see, and the mode the
user had chosen before the connection dropped is remembered and restored if it returns while they
are still standing there — a forced answer is not their answer, and keeping it after the reason
for it went away is the one way this page can lie.

## 2. The job re-asks, and then may not fail

`appsetup` runs last of the chroot work — after `imageidentity`, before `umount` — and it starts
by re-checking connectivity itself, with curl on the host against the same `@HOME_URL@` the
greeting checks. The page's verdict is minutes old by then; the difference between the two answers
is a cable plugged in during the summary page (apps should install) or pulled after it (a download
should not start). Offline, the job skips both its passes and says so.

Online, it does two things, in this order:

1. **installs** the refs GlobalStorage's `appsSelected` names — resolved by the page: *typical* is
   published as the whole list, *none* as empty, *custom* as the ticked subset pre-intersected
   with the configured ids, all in file order. The job never learns what "typical" means, so it
   cannot disagree with the conf about what the set was.
2. **updates** every flatpak in the target, always — the half the page never asked about. The
   payload's five apps were pinned at build time by `apps.lock`; this is the only moment between
   the build and the first boot that has both the store and a network.

And that is the whole job, because of the rule its header states: **no download failure may fail
an install.** When this job runs, the operating system is on the disk — image written, bootloader
placed, accounts created — and every failure mode left is "a download did not finish". Failing for
that hands the user a working machine described as broken, with a retry that rewrites their disk
for the sake of an app Discover installs in a minute. Every flatpak failure warns, names what to
do later, and returns `None`; the job's single fatal case is a missing `rootMountPoint`, which is
not this job's failure at all.

## 3. DNS in the chroot, the one thing imagedeploy does not provide

`flatpak` resolves `dl.flathub.org` from inside the chroot, and glibc reads `/etc/resolv.conf`
there — which is systemd-resolved's **stub symlink**, pointing into `/run/systemd/resolve/`. The
chroot's `/run` is a fresh tmpfs, so the symlink dangles, and even a bound stub would answer
`127.0.0.53` to nobody: there is no resolved listening inside the chroot.

The job binds `/run/systemd/resolve/resolv.conf` — resolved's record of the **real upstream
servers**, the file documented for exactly this consumer — over the target's resolver config,
creating the mountpoint under the tmpfs when the symlink dangles. A **bind mount**, never a
written file: the target's `/etc` is an overlay whose upper persists, so a copied resolv.conf
would shadow resolved's symlink on the installed machine, and deleting it again would whiteout the
lower's symlink out of existence. The stock `umount` module tears the mount down — `emergency:
true`, so it runs even when this job has warned its way out of something.

## 4. Why every word this page shows is a C++ property

The builder's lupdate (`dev-qt/qttools` 6.11) is built **without QML support** — `missing
qml/javascript support`, it says, and extracts nothing from a `.qml`. A `qsTr()` in this module's
QML would never reach the branding catalogue and would render English in all nine languages the
language page offers. (The sibling pages carry that gap today — see §7.)

So `Apps.qml` contains no `qsTr()` call at all: the three row titles, the subtitles, the button,
the offline note and the headline are all `tr()` properties on `AppsConfig`, which lupdate
extracts, the catalogue translates, and a language change re-says. The cost is nothing the page
was not already paying — the headline and the offline note were C++ properties anyway, because
they carry the product name and the connectivity state.

## 5. What moves

| what | where |
|---|---|
| `apps` view module | `config/portage/overlay/distro-base/distro-calamares-apps/` — the fifth, clone of the disk ebuild's shape (QML in a `QQuickWidget`, `calamares_add_plugin`, the `KF6CoreAddons` fix, `INSTALL_CONFIG ON`) |
| `appsetup` job | `config/calamares/local-modules/appsetup/` — `module.desc` (weight 20) and `main.py` |
| the offer | `config/calamares/modules/apps.conf` — *not* a template, like `locale.conf`: the list is facts about Flathub, not about this build. The packaged fallback in `files/apps.conf` carries the same six, and the test asserts the two agree app for app |
| the job's knobs | `config/calamares/modules/appsetup.conf.in` — `internetCheckUrl` (the same `@HOME_URL@` the greeting renders), `remote`, `flathubUrl`, `installTimeoutS`, `updateTimeoutS` |
| the sequence | `apps` in `show:` after `accounts`, immediately before `summary`; `appsetup` in `exec:` after `imageidentity`, before `umount` |
| the atom | `distro-base/distro-calamares-apps` in `config/portage/sets/installer` — the sixth, and the first that replaces nothing |

`flathubUrl` is a literal, not a rendered token, on purpose: stage 40's `FLATHUB_SRC` is rewritten
to a builder-local path when the vendor archive substitutes for the network, and a medium is not
a build. It exists only for the fallback that adds the remote to a target built with
`INSTALLER_PAYLOAD_FLATPAKS=0`, whose bare `/var` seeded no flatpak store at all.

## 6. Tests

`tests/test-installer.sh` §6f: the six ids in both confs, in file order, none in `apps.lock`; the
two `internetCheckUrl`s are one URL; the offline rule in both halves (the `onActivate` re-ask, the
forced mode, the two disabled choices, the job's own probe and skip); the job's **single** error
tuple; the noninteractive install/update invocations; the unconditional update; the resolver
bind; the two GlobalStorage keys; the QML-binding and NOTIFY-emission structural checks, the same
python the disk page is held to; no `qsTr(` call in the QML; and the plugin-name/sidebar/resource
trio. Plus: six local modules, six `@installer` atoms, six overlay ebuilds (each count argued for
in its comment), and both ordering rules — `apps` after `accounts` before `summary`, `appsetup`
after `imageidentity` before `umount`.

## 7. Known limits

- **The typical set is pinned by nothing.** It is downloaded at install time from whatever Flathub
  served that minute, by design — there is no commit to pin an install that has not happened yet,
  and pinning it would mean shipping it, at which point it is `FLATPAK_PREINSTALL` and not this
  page. The trade is stated on the page (installed "while the installer runs") rather than hidden.
- **No download progress.** flatpak reports nothing usable over its CLI, so the job's weight (20)
  buys the progress bar its segment, not movement inside it. The timeouts (`installTimeoutS`
  2400 s) are outer walls, and both end in a warning and a finished install.
- **The sibling pages' QML strings are untranslated**, and were before this page existed: the same
  lupdate limitation (§4) means `Accounts.qml` and `Disk.qml` `qsTr()` strings have never reached
  the catalogue — plan/22 §8's known limit, now visible as ~73 unfinished entries in the `.ts`
  files (accounts and disk C++ strings among them) that this module's translation pass did not
  fill. The fix is either a QML-aware lupdate on the builder or the §4 treatment for those two
  pages; both are work, and neither is this page's.
- **`LanguageNames` re-vanishes on every `update-translations.sh` run**, because no source
  declares the pseudo-context. The translations survive; they must be un-vanished again before
  lrelease, or the picker's second line drops. A run that ends with check-translations passing is
  a run that ended correctly.

## Changes to other documents

- `config/calamares/README.md` — the module table gains `apps` and `appsetup`; the header gains
  this plan.
- `settings.conf.in` — the two sequence entries and their comments, written in that file's voice.
- `config/portage/sets/installer` — the sixth atom, with the argument for it.
