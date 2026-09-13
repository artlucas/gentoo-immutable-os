# 21 — The installer's accounts page

The installer asks "who will use this computer?" three times, in two places, and never as a
question with one answer.

Stock `users` draws a local account form with an **"Use Active Directory" checkbox** bolted to the
side of it. That checkbox is additive by construction: `Config::createJobs` appends an
`ActiveDirectoryJob` and then still runs `SetupGroupsJob`, `CreateUserJob` and `SetPasswordJob`
(`Config.cpp:1088-1104`), so a domain-joined install *also* gets the local account typed above it.
plan/18 §7.2 accepted that, correctly for its time, and `config/calamares/modules/users.conf.in`
recorded the price in a comment: "a strict either/or would need a C++ view module". Then plan/19
Phase D built a C++ view module for something else — managed enrolment — and put it on a **second
page**, with a second checkbox, asking about the same decision.

So the medium currently presents three mutually exclusive identity mechanisms as one form plus two
independent checkboxes. They are not independent. `<id>-managed enroll` refuses to run on a machine
with `/etc/sssd/sssd.conf` and `<id>-domain join` carries the mirror check (plan/19 §8.7); the UI is
the only layer that ever suggested otherwise.

This document replaces both pages with one module, `accounts`, where the mechanism is a **choice**
and the fields belong to the choice.

## 1. What it looks like

Two screens in one view step. The choice is the whole of the first one; the chosen mode's fields
are the whole of the second.

```
 screen 1                                    screen 2
 ┌────────────────────────────────────┐      ┌────────────────────────────────────┐
 │ How should people sign in to this  │      │ [icon] Join an enterprise domain   │
 │ computer?                          │      │        accounts come from AD       │
 │                                    │      │                                    │
 │  ( ) 👤  Local accounts only       │      │ ────────────────────────────────── │
 │         one account, on this …     │      │ The domain        Local admin      │
 │         works with no network      │      │  Domain:   [   ]   Username: [   ] │
 │                                    │      │  Join acct:[   ]   Password: [   ] │
 │  ( ) 👥  Managed system            │  →   │  Join pw:  [   ]   Repeat:   [   ] │
 │         accounts come from your …  │      │  DC addr:  [   ]                   │
 │         needs a network now        │      │  [Check domain]                    │
 │                                    │      │  ▸ Advanced                        │
 │  (•) 🖥  Join an enterprise domain │      │ ────────────────────────────────── │
 │         accounts come from AD …    │      │      Computer name: [ immos ]      │
 │         needs the domain name …    │      │                                    │
 └────────────────────────────────────┘      └────────────────────────────────────┘
      ← Back   Next →                             ← Back   Next →
   leaves the page    to screen 2               to screen 1    leaves the page
```

### 1a. Why two screens, and why it costs no new module

**Measured, not guessed.** The page is rendered offscreen against the built medium's own Qt,
Kirigami and qqc2-desktop-style — `chroot /work/target-installer`, `QT_QPA_PLATFORM=offscreen`,
`AccountsConfig` stubbed as a QML singleton — and the content item's `implicitHeight` compared
against the `ScrollView`'s `availableHeight`. The viewport Calamares gives a view module is
**710×536**: the 900×600 `windowSize` from `branding.desc`, less the 190px sidebar and the 64px
navigation bar (`CalamaresWindow.cpp:503` and `:509`; `mainLayout` is unmargined and
`ViewManager` applies `widgetMargins` only when the step's widget has a layout, which a bare
`QQuickWidget` does not).

| | one page | two screens |
|---|---|---|
| the choice | 181 px, always on screen | 255 px, its own screen |
| local accounts | 363 px | 258 px |
| managed | 350 px | 261 px |
| **enterprise domain** | **595 px** | **331 px** |
| domain, *Advanced* open, a failed check and three validation errors | 646 px | 481 px |

One page scrolled in domain mode before anybody had typed anything, and the local administrator —
the account that matters most precisely when the domain is unreachable — was the half below the
fold. Two screens fit in every state.

**The wiring is four functions Calamares already calls.** `ViewManager::back()` calls
`step->back()` instead of leaving the module whenever `isAtBeginning()` is false, and
`ViewManager::next()` calls `step->next()` instead of advancing whenever `isAtEnd()` is false
(`ViewManager.cpp`). Both are pure virtuals `AccountsViewStep` already had to implement — they
returned `true`. Reporting `AccountsConfig::step` from them is the entire change, so:

- the window's own **Back** and **Next** move between the screens,
- **Back** on screen 1 still goes to the partition page, exactly as before,
- the sidebar still shows one entry, and there is still one module, one `onLeave()`, one
  `setConfigurationMap()`.

**Screen 2's header is a label, not a control.** It says which choice the fields belong to,
because on that screen the choice itself is off-screen. It draws no button of its own: the
window's Back is the one way back to the chooser, which is where every other page in the
installer puts it, and one movement with one control is one thing to keep working.

**Selecting a mode does not advance.** A radio button that navigates punishes a mis-click by
throwing away the screen you were reading, and the three options are meant to be compared with
one of them selected. `Next` advances; on screen 1 it is enabled as soon as a mode is picked and
gates on nothing else — in particular not on the hostname, whose field is on the screen you have
not reached yet.

**The space screen 1 gained buys a third line per option**: what that choice will ask of you
before the install can continue. "Needs a network connection and an enrolment code now, before
the disk is written" is the sentence somebody wants *before* choosing managed mode, and there was
nowhere to put it when the chooser had to share the page with a form.

| mode | fields | creates |
|---|---|---|
| **local** | full name, username, password ×2, computer name | one local administrator (`wheel`, `video`, `pipewire`), the subuid range, the hostname |
| **managed** | enrolment code, computer name | an enrolment; the accounts arrive as `/etc/userdb` records from the signed bundle (plan/19 §2) |
| **domain** | domain, join account, join password, DC address, and under *Advanced* computer OU / admin group / computer name — plus a **local administrator** defaulting to `admin` | the sssd join (plan/18 §4) and one local administrator |

`Next` on screen 2 is disabled until the chosen mode validates. The two modes that create a local account
validate the way stock `users` did — a legal username not in `forbidden_names`, two matching
passwords through libpwquality — and mode **managed** validates differently, which is §3.

Three things are deliberately one field rather than two:

- **Computer name is the hostname in every mode**, and in managed mode it is also the device name
  the control plane shows. The old managed page had its own "Name for this computer" beside the
  users page's hostname, and nothing reconciled them.
- **The domain's computer account name** defaults to the hostname and is only in *Advanced*, where
  `<id>-domain --computer-name` already lived.
- **The local administrator in domain mode is the failsafe**, not a second concept. Its username
  defaults to `admin` because it is rarely the account anyone signs in with day to day.

### 1b. The style the page is drawn in, and the guard that never fired

Kirigami chooses its platform integration plugin from the **Qt Quick Controls style's name**, and
that plugin is what initialises the icon theme. So the style is not a matter of taste on this
page: the wrong one costs Breeze's colours, Breeze's metrics **and every icon**, together.

`AccountsViewStep`'s constructor asks for `org.kde.desktop`, and for its first three weeks it
asked behind this guard:

```c++
if ( QQuickStyle::name().isEmpty() )   // never true
```

`QQuickStyle::name()` does not report "nobody has chosen a style" — it *resolves* one and reports
the answer, and on Linux since Qt 6.7 the answer with nothing configured is `Fusion`. Measured in
the medium's own Qt under the environment `pkexec calamares` actually gets, `name()` is `"Fusion"`
before the call and the guard never fired once. The page had never been drawn in the style it was
written for, and the first VM boot showed all three symptoms at once: the radio indicator at the
far right of each row (Fusion's `RadioDelegate` puts it at `width - width - rightPadding`), an
opaque white slab behind every row (Fusion fills delegate backgrounds with `palette.base`), and no
icons anywhere.

> **The call itself moved in [plan/22](22-installer-language-page.md) §3b, and the guard did not.**
> `QQuickStyle::setStyle()` is ignored once anything has imported Qt Quick Controls, and
> `ModuleManager::loadModules()` walks the sequence in order — so the right owner of that call is
> whichever module is *first*, which is now the language page rather than this one. This
> constructor keeps its guard and its warning unchanged, and their reason changes from "in case
> another module ever loads QML before this one" to "one now does, and this line is how you find
> out if a third is inserted ahead of it".

The guard is the **environment variable** instead, because it is the only thing in reach that
expresses a choice — a resolved default is not one:

```c++
if ( qEnvironmentVariableIsEmpty( "QT_QUICK_CONTROLS_STYLE" ) )
```

`pkexec` is why the installer has to set its own: Plasma exports `QT_QUICK_CONTROLS_STYLE` (and
`XDG_CURRENT_DESKTOP`, which is how Qt finds the KDE platform theme), and
`installer-autostart.desktop` runs `pkexec calamares`, which sanitises the environment. Somebody
debugging with `QT_QUICK_CONTROLS_STYLE=Basic` still gets Basic, and the constructor logs a
warning naming whatever style it ended up in — the line to look for if a future module loads QML
before this one and `setStyle()` arrives too late to matter.

**The chooser's rows no longer depend on any of that.** They are `RadioButton`s with a hand-built
`contentItem` and `background`, not `RadioDelegate`s, because *which side the indicator is drawn
on* is a style decision: `qqc2-desktop-style` puts a `RadioDelegate`'s indicator at
`horizontalPadding`, Qt's own Basic and Fusion put it at the opposite end of the row. `RadioButton`
is the control all three place at `leftPadding` — and Basic and Fusion decide that by asking
whether `text` is set, so the control keeps a `text` it never draws, or the bullet parks itself in
the middle of the row. The row's background is transparent until it is hovered, focused or chosen,
so no style's opaque delegate ground can come back. Rendered under both `org.kde.desktop` and the
Fusion fallback to prove it.

## 2. Why the mechanism is a compiled plugin with a QML face

Calamares' module interfaces are enumerated, not extensible:

```c++
// src/libcalamares/modulesystem/Descriptor.h
enum class Interface { QtPlugin,  // Jobs or Views
                       Python,    // Jobs only
                       Process }; // Deprecated interface
```

`ModuleFactory.cpp:53` accepts only `Interface::QtPlugin` for `Type::View`. There is no QML module
interface and no Python one — plan/18 §7.2 and plan/19 §7.3 both quote this, and it is still true.

What *is* available is that a `QtPlugin` view may render QML internally, which is exactly what
upstream's `usersq`, `welcomeq` and `packagechooserq` are. This module does the same, and the
consequence is worth stating plainly because it is the difference between this page and its
predecessor: `ManagedPage.cpp` was three controls in a `QFormLayout` and said so — "this page has
three controls and needs none of it". This page has three modes, a dozen conditional fields, live
validation on five of them, a password meter and an asynchronous network action with four visible
states. That is a UI, and a declarative one is the right shape for it.

The split with the exec phase is unchanged from Phase D and is the reason this file is short:
**the page collects, a Python job does the work.** A job can be a script.

```
AccountsViewStep   ViewStep: the widget, isNextEnabled(), prettyStatus(), onLeave()
AccountsConfig     one QObject, all state — what QML binds to and what onLeave() publishes
PasswordCheck      libpwquality, so the meter and the rule are the same code
qml/Accounts.qml   the mode selector, and the three forms it reveals
```

`widget()` returns a `QQuickWidget` whose source is a **Qt resource compiled into the plugin**.
`Calamares::QmlViewStep` exists and would work, but it loads QML by name out of the branding
component directory or `/usr/share/calamares/qml/` — a second install path, a second search order,
and a failure mode (a page that renders blank) that is invisible until the medium is booted. A
`.qrc` cannot be half-installed.

Two runtime details are not optional and are both a line of C++:

- **`QQuickStyle::setStyle("org.kde.desktop")`**, set once in the plugin factory and only when no
  style has been chosen. Without it Qt Quick Controls fall back to the Basic style and the page
  looks like nothing else on the medium; `qqc2-desktop-style` and `qqc2-breeze-style` are both
  already on it (`installer.lock:319`, `:364`).
- **`tr()` and `qsTr()`, never `i18n()`.** plan/19 §7.2 measured what `i18n()` does with no
  `KLocalizedContext` on the engine: `ReferenceError: i18n is not defined`, and an empty string
  rendered. Calamares is a C++ host and could install one, at the cost of a ki18n dependency this
  page has no other use for. Qt's own translation macros are already wired into `libcalamares`.

Nothing here needs a new package in the image. `kirigami`, `kirigami-addons`, `qtdeclarative` and
`libpwquality` are all in `installer.lock` today, the last one because Calamares' own password
meter pulls it in. `Qt6::QuickWidgets` resolves for the same reason it resolved for the Phase D
module: `CalamaresConfig.cmake` re-finds Qt6 with the components accumulated from Calamares' own
imported targets, and Calamares links QuickWidgets for its `*q` modules.

**And one thing an out-of-tree plugin has to switch on for itself: `set(INSTALL_CONFIG ON)`.**
`calamares_add_plugin()` globs `*.conf` out of the plugin's own directory and then guards the
install on `if(INSTALL_CONFIG)` — an option Calamares' top-level `CMakeLists.txt` defines for its
in-tree modules and `CalamaresConfig.cmake` does not export. Out of tree it is simply undefined,
reads as false, and the packaged `accounts.conf` is not installed. Nothing warns, because the glob
*did* find the file, so the macro also skips the "NO_CONFIG should be set." advice it prints for a
plugin with no configuration at all. Measured on the built target root, where
`/usr/share/calamares/modules/` held no `accounts.conf` after a complete emerge — the medium never
noticed, because stage 40 renders `/etc/calamares/modules/accounts.conf` and `/etc` is searched
first. The Phase D module had the same hole and the same reason for not showing it.

`NO_CONFIG` is the other way to silence that glob and would be much worse than leaving it: it
stamps `noconfig: true` into `module.desc`, and Calamares then never calls `setConfigurationMap()`
at all. No modes offered, no groups, no forbidden names — an empty page, from a one-word change
that reads like tidying up. `test-managed.sh` asserts the option is on and that word is absent.

## 3. The one rule this reverses

plan/18 §7.4 and plan/19 §8.6 say the same thing in different words, and the whole installer is
built around it:

> A domain controller that is unreachable while someone installs a machine is a Tuesday. An
> installer that treats it as a fatal error hands the person a disk with no account on it, still
> autologging into the live user, presented as a failed install.

Every identity surface obeyed it. `ManagedViewStep::isNextEnabled()` returns `true`
unconditionally. `managedenroll/main.py` returns `None` on every path. `/usr/bin/realm` exits 0 even
when the join did not happen. All three are right, and all three depend on a premise: **that a local
account was created anyway**, so the machine is usable and the failure is a one-command fix.

Managed mode as specified here has no local account. The premise is gone, and with it the
conclusion: an install that reaches `finished` having neither created a local user nor written a
single `/etc/userdb` record is a disk nobody can log into. `enrollment-pending.json` would tell
"sudo `<id>-managed enroll --code CODE`" to an audience of nobody.

So for **managed mode only**, the page blocks. And it blocks by *doing the thing*:

```
[ Check and continue ]   →   <id>-managed enroll --code <code> --name <computer name> \
                                                 --root /run/<id>-accounts/enroll
```

That runs **before the disk is touched** — the page is in the `show:` phase, ahead of `summary` and
the `prompt-install` confirmation — so the only irreversible act in the sequence, spending a
single-use code with a 15-minute TTL, happens where failing costs nothing. Unreachable control
plane, expired code, code already used: all four states are visible on the page, in the client's own
words, and `Next` stays disabled until one of them is not the answer.

The scratch root is seeded before the client runs, because the client checks:

| seeded | why |
|---|---|
| `<scratch>/etc/` | `enroll` refuses a `--root` with no `etc/` (`distro-managed.in:1049`) |
| `<scratch>/etc/machine-id`, **empty** | it refuses a root with no machine-id at all (`:1057`), and an empty one hashes to the same empty `hw_fingerprint` the current `--root $rootMountPoint` path already sends, because the image ships an empty machine-id and the real one is generated on first boot |
| `<scratch>/etc/hostname` | `device_facts()` reads it, so the org sees the name that was typed rather than the medium's |

`enable_timer()` runs `systemctl --root=<scratch> enable` against a tree with no unit files and
fails; `systemctl()` ignores a non-zero exit unless asked to check, so this is silent and harmless.
The timer is enabled in the *target* by the job.

**One more thing can still produce a machine with no accounts**, and the page checks it too: a
bundle that grants this device nobody. After a successful enrolment the page reads
`<id>-managed status --json --root <scratch>` and keeps `Next` disabled, with a different message,
until at least one user is granted. An organisation that has not yet assigned anyone to a new
machine is a normal state on the web side and a brick on this side.

**Leaving managed mode releases the device.** Pressing Back, switching to another mode, or editing
an accepted code runs `<id>-managed leave --purge --force --root <scratch>`, which tells the control
plane. Without it, every abandoned install leaves a device record in the org that nothing will ever
check in.

Modes **local** and **domain** keep the old rule exactly. A domain join still cannot fail an
install: the local administrator is created either way, `<id>-domain` verifies before it writes, and
the failure is recorded in `domain-pending.json` for `<id>-domain status` to report.

## 4. The page↔job contract

`onLeave()` publishes to GlobalStorage. The keys that already had consumers keep their names, so
`imagedeploy` (which writes `/etc/hostname` as soon as the /etc overlay is mounted) and
`imageidentity` (subuid ranges, the first-boot hostname stamp) are untouched:

```
hostname                          imagedeploy, imageidentity          all modes
username                          imageidentity                       local, domain
accountsMode                      accountsetup                        local | managed | domain
userFullName userGroups
userShell homePermissions         accountsetup                        local, domain
managedEnrollmentScratchRoot
managedDeviceName                 accountsetup                        managed
managedOrgName                    nobody — the log                    managed
domainName domainJoinUser
domainDcAddress domainOu
domainAdminGroup
domainComputerName               accountsetup                        domain
accountsSecretsPath              accountsetup                        local, domain, managed
```

`managedOrgName` is the one key with no reader, and it stays for the operator rather than the
code: it is what makes `calamares.log` say *which* organisation a machine was enrolled into, the
first question asked about an install that produced the wrong accounts. There is deliberately no
`managedEnrollmentRequested` — `managedenroll` needed one because it was a job with no other way
to know whether the optional page in front of it had been used, and `accountsMode` now says the
same thing. Two keys for one fact are interesting only when they disagree.

**No password is in that list, and neither is the enrolment code.** Calamares can dump GlobalStorage
to its log, and the old `managedEnrollmentCode` key put a live credential there. The two passwords go
to `/run/<id>-accounts/secrets.json`, mode 0600, on the live medium's tmpfs; GlobalStorage carries
the path. The job reads it once and unlinks it in a `finally`, whatever else happened. The code is
never written anywhere: by the time the job runs, the page has already spent it.

## 5. `accountsetup`

One Python job, replacing stock `users` and `managedenroll`, in the exec sequence where `users` was.

1. **The local account** (local, domain). `useradd -m -U -G wheel,video,pipewire -s /bin/bash -c
   "<full name>"`, the home mode, then `chpasswd` with the password on stdin — through
   `libcalamares.utils.target_env_*`, which chroots into `rootMountPoint`. This is stock `users`'
   three jobs, and it works on an immutable root for the one reason it always did: `imagedeploy`
   mounted the /etc overlay first, so a write to `/etc/passwd` is a copy-up (plan/16 §5.2).
2. **The hostname.** `/etc/hostname` again (idempotent — `imagedeploy` wrote it early so the domain
   join would not create the computer account under the medium's name) and `/etc/hosts`, which is
   the half of stock `users` nothing else covered.
3. **The transplant** (managed). Copy `<scratch>/var/lib/<id>/managed/` into the target, then
   `<id>-managed apply --root <target>`, then enable the sync timer in the target.
4. **The join** (domain). `<id>-domain join --domain … --user … --root <target> --password-stdin`,
   with `--ou`, `--admin-group` and `--computer-name` when given — the three options plan/18 §7.1
   listed as "already options on `<id>-domain`; only the page cannot express them".

**This job may fail the install, and only in step 1.** That is a deliberate difference from every
other job on this path. A `useradd` that fails leaves a machine with no way in and no way to fix it;
saying so is better than a green `finished` page. Steps 3 and 4 keep the discipline they inherited
and return `None` on every path, writing `enrollment-pending.json` or `domain-pending.json` so the
installed system can explain itself.

### `/usr/bin/realm` is deleted

The shim existed for exactly one caller: Calamares' `ActiveDirectoryJob`, which hardcodes the name
`realm`. With the stock users module gone there is no such caller, and the job calls `<id>-domain`
directly. The shim's exit-code mapping (2 unreachable, 3 credentials rejected, 4 clock skew) and its
`domain-pending.json` writer move into `accountsetup` unchanged; `tests/test-domain.sh` drives them
there instead. One join implementation, and now one caller of it per surface rather than two hops.

## 6. `<id>-managed apply`

The transplant needs one new client command, and the reason is `/etc/subuid`.

Everything the managed client writes into `/etc` is a file it owns and can copy: `userdb` records,
their `<uid>.user` symlinks, `.membership` files, `sudoers.d/30-managed-admins`, two polkit rules.
`/etc/subuid` and `/etc/subgid` are not — they are **appends** to files the target already has,
carrying the local administrator's range and the live user's, and only the client knows how to add
its own lines without disturbing them (plan/19 §8.2).

So the job does not copy `/etc` at all. It copies the **state directory** — `enrollment.json`,
`bundle.json`, `bundle.sig`, `serial`, `owned.json`, the event queue — and then asks the client to
apply that cached bundle into the target with its own code:

```
<id>-managed apply --root <target>       # no other arguments; it applies what that root holds
```

which is the second half of `do_sync()`: `gpgv` over the received bytes **before parsing** them,
the serial high-water check, `render()`, the writes, `owned.json`, the subuid append. Factored into
`apply_bundle(paths, raw, sig)` so `sync` and `apply` cannot drift.

It is not only the installer's. On a running machine it re-applies the cached policy with no
network, which is what a user whose `/etc` overlay was rolled back actually wants, and it gives the
offline suite an *apply* to diff against `tests/managed-golden/` beside the existing
`--print-config` render.

## 7. What moves

| | |
|---|---|
| **new** | `<id>-base/<id>-calamares-accounts` (overlay), `local-modules/accountsetup/`, `modules/accounts.conf.in` |
| **gone** | `<id>-base/<id>-calamares-managed`, `local-modules/managedenroll/`, `modules/users.conf.in`, `modules/managed.conf.in`, `system/realm.in` |
| **changed** | `settings.conf.in` (one page, one job, no `@CAL_MANAGED_PAGE@` token — the page is mandatory now, so its absence is a stage-40 `die`), stage 40 §2d, `sets/installer`, `distro-managed.in`, both installer locks |

`accounts.conf.in` inherits everything `users.conf.in` and `managed.conf.in` said, comments
included: `defaultGroups` with `must_exist` and the note on why `audio` is absent,
`passwordRequirements`, `user.forbidden_names`, `hostname.template`, `organisationHint`. It adds
`failsafeUserName`, `enrolScratchRoot` and `modes`, the last so a profile can offer fewer than
three. None of that file's reasoning changed; only the module reading it did.

The cracklib step in stage 40 stays exactly as it is. libpwquality's dictionary check is
compiled-in, cracklib's `pkg_postinst` never runs under `ROOT=$TARGET`, and without the dictionary
this page rejects every password with a dictionary-check error — the same trap, in the same place,
for the same reason.

## 8. Tests

| | |
|---|---|
| `test-installer.sh` | `accounts` and `accountsetup` in the sequence and in the descriptor checks; `users` and `managedenroll` join the *dropped* list; the cracklib assertions retarget `accounts.conf`; nothing references `/usr/bin/realm` |
| `test-domain.sh` | the argv contract moves from the shim to the job, exit-code mapping intact |
| `test-managed.sh` | the GlobalStorage key list, an assertion that **no** published key holds a password or a code, and `apply --root` against the golden bundle, offline |
| `test-managed.sh`, the page | every `accounts.*` binding in the QML resolves to a property, slot or enum; every `Q_PROPERTY` is `CONSTANT` or notifies a signal something emits; the four `ViewStep` overrides report `AccountsConfig::step` rather than a constant; `Next` on the chooser gates on a mode having been picked; no QML binding compares `step` to a number |
| stage 70, `--with-test-api` | **T-MAN-4 splits.** (a) fixture down: `Check and continue` fails, `Next` stays disabled, switching to local mode installs a working machine. (b) fixture down *after* a good enrolment: the install completes and the disk boots with the transplanted bundle's users — the point of enrolling before the disk is written |
| stage 70, `--with-test-dc` | a domain install has the join **and** the local `admin` |

Both stage-70 rows are **blocked, not pending**, and on something this change does not bring any
closer: they drive a real install, and stage 70 has no way to drive Calamares unattended. That is
plan/16 §10 question 5, the same thing that has blocked T-DOM-1 since plan/18, and the harness
gap is now shared by four cases rather than one — which is the argument for closing it, in its own
change, rather than for writing a test here that cannot run.

The two-screen navigation is in the same position — the only way to press Back is to run the
installer — so it is held by the mechanical assertions in the row above. They are worth listing
because each one closes a failure that compiles: `isAtEnd()` left at `return true` makes `Next`
leave the page from the chooser and publish a mode whose fields nobody filled in, and a QML
binding that reads `accounts.step === 1` keeps working until somebody renumbers the enum. Every
one of them was mutation-tested against exactly those edits.

What holds T-MAN-4 in the meantime is offline and property-shaped, recorded in plan/07's table:
`accountsetup`'s network-facing functions contain no `return (` at all, so no unreachable service
can fail an install, while `create_local_user` deliberately does contain one. `test-managed.sh`
asserts that per function rather than per file, because this job now holds both disciplines and a
file-level grep could no longer tell them apart.

## 9. Known limits

- A hard quit of Calamares between a successful managed enrolment and the install leaves a device
  record in the org with no machine behind it. The web UI deletes it; nothing here can.
- Managed mode needs a network at page time. `language.conf` (`welcome.conf` until plan/22)
  lists `internet` under `checks:` but not
  `required:`, so the installer still starts offline and this mode explains itself.
- The enrolment's `hw_fingerprint` is empty, exactly as it is today: the machine-id that will
  identify the installed machine does not exist until its first boot.
- Zero-touch enrolment (plan/19 §7.3 route 2) is still unimplemented, and now has no job of its own
  to arrive in. It belongs in a firstboot unit reading a systemd credential, not on this page.
