# 26 — Five answers the installer was making the user give twice

Four pages into having its own installer, the friction shows. The disk page ends in a checkbox
whose whole job is to arm the Next button — an interaction where the safety and the clutter are
the same widget. The accounts page opens on a question most machines answer the same way, refuses
a password the person typing it may have every reason to choose, and offers no way to say "this
computer can log itself in". And the sidebar centres every step name, which reads like a list of
headings rather than a list of steps.

This plan is five small changes, one mechanism, and one decision about when a question is worth
asking twice.

## 1. The disk page: the checkbox becomes a question at the door

The checkbox (plan/24 §2) put the confirmation *before* the button: Next stayed dark until the
box was ticked, so the erase was agreed to in the same glance that chose the disk. What it cost
was a permanent piece of UI whose state (tick, no tick) had to be managed — cleared on disk
change, cleared on rescan, never auto-ticked — for a decision the user makes exactly once, in a
moment, on the way out.

The replacement puts the confirmation *at* the button. Next lights up when a disk is selected;
pressing it asks the question, and only "Erase and install" leaves the page.

The mechanism is the one the accounts page already runs (plan/21 §1, `AccountsViewStep`):
`ViewManager::next()` calls `step->next()` instead of advancing the sequence whenever the step
reports `isAtEnd() == false`. So:

- `DiskConfig::nextEnabled()` gates on the disk alone — `isInstallable(m_currentIndex)`.
- `DiskViewStep::isAtEnd()` returns `m_config->confirmed()`, and `next()` asks for the
  confirmation: `DiskConfig::requestConfirmation()` emits `confirmationRequested()`, the QML
  opens a `Kirigami.PromptDialog` naming the disk (`selectedDiskTitle`, the same
  `DiskModel::rowTitle` composer the row and the summary page name it by) and repeating
  `lossSummary`.
- The dialog's accept button calls `Q_INVOKABLE acceptConfirmation()`, which sets `confirmed`,
  which flips `isAtEnd()` — and the view step, hearing `confirmedChanged`, completes the advance
  with `ViewManager::instance()->next()`. The second `next()` is the one that leaves.

**The question is asked on every press.** `onLeave()` publishes to GlobalStorage and then clears
`confirmed`, so re-entering the page always finds the question unasked — going Back from accounts
and pressing Next again re-asks, exactly as pressing it the first time did. This is deliberately
unlike the old checkbox, which stayed ticked: a tick was *state about a disk*, kept until the
disk changed, while a dialog answer is *an event*, and the erase it agrees to is an event too.
The disk-change and rescan clears stay (tests pin them); they are now belt and braces, because no
answer survives leaving the page anyway.

`publish()` keeps writing `diskConfirmed` — as the explicit `isInstallable && confirmed` rather
than the old `nextEnabled()`, whose meaning this plan changes. The `disksetup` job's re-check is
untouched and still passes: the only forward leave from this page follows an accepted dialog, so
GlobalStorage always carries `true` at final passage.

## 2. The accounts page: the choice most machines make, already made

plan/21 opened the chooser with nothing selected, on the argument that "a mode is a decision, and
there is no default that is right for everybody". A version later, the counter-argument is the
one the page itself makes for the disk page: one disk, one selection. Most machines are
household machines; the enterprise modes exist, are offered, and are the exception.

So `setConfigurationMap()` selects **Local accounts only** when `modes:` offers it — the radio is
pre-ticked, the chooser's Next is lit, and the page's first screen becomes a confirmation rather
than a question. `NoMode` survives only in a profile that does not offer local at all, where the
old rule (nothing selected until somebody selects) still holds, because there nothing can be
pre-selected honestly.

## 3. The accounts page: a weak password is a warning, not a wall

libpwquality's verdict — too short, a dictionary word, one character class — currently keeps Next
dark. That is the right default and the wrong law: the person installing a kitchen computer
knows something about the threat model the page does not, and a hard block hands them the
one thing an installer must never hand them: a reason to pick a worse password *pattern*
(password1!, password2!) that satisfies the checker.

The change mirrors §1's mechanism, one screen later:

- `nextEnabled()` (local and domain modes) stops requiring `passwordValid`; it requires the
  password **complete** — non-empty and matched — with strength delegated to the prompt. An
  empty or mistyped repeat still blocks, as before; only *strength* becomes confirmable.
- `AccountsViewStep::isAtEnd()` becomes `onFields() && passwordSettled()`, where settled means
  `passwordValid || (allowWeakPasswords && weakPasswordAccepted)`. A Next from the fields screen
  with an unsettled password opens the prompt instead of leaving: **"Use this password
  anyway?"**, with `passwordMessage` — libpwquality's own reason, already translated — as the
  warning. "Use anyway" accepts and completes the advance; Cancel returns to the fields.
- Acceptance is withdrawn by the next edit of either password field, or a mode change. Unlike
  §1's answer it is *not* withdrawn by leaving the page: a chosen password is a decision, an
  erase is an event.
- `passwordRequirements.allowWeakPasswords` (default true) turns the wall back on for profiles
  that want it, in both `modules/accounts.conf.in` and the packaged fallback.

The red message under the field and the score meter stay as they are: they are the warning that
arrives while typing; the dialog is the one that arrives on the way out.

## 4. The accounts page: auto-login, offered rather than forbidden

plan/21 dropped `doAutologin` wholesale — "the installed system must not autologin" — and
`imageidentity` enforces it unconditionally, writing a drop-in with an empty `User` over the
live medium's `10-autologin.conf`. For a household machine that is one password too many on
every boot, and the person best placed to decide is standing on the page.

So local mode grows a checkbox — **"Log in automatically as this user"**, unticked by default —
publishing `autoLogin: true` to GlobalStorage only in local mode. `imageidentity`'s
`write_autologin_dropin` grows the other branch: when GlobalStorage says `autoLogin` and carries
a `username`, the drop-in (renamed `20-autologin.conf`, a neutral name now that it can say either
thing) writes `[Autologin] User=<username> / Session=plasma / Relogin=false` — the same three
keys `10-autologin.conf.in` sets, so the enabled state is a mirror of the live medium's, not an
improvisation. The disable branch is byte-for-byte what it wrote before. The mtime caveat in that
function's comment still holds for both branches.

Managed and domain modes grow nothing: the checkbox is on `LocalForm` only, and `publish()`
gates the key on `m_mode == Local`.

## 5. The sidebar: read from the left

The step list is centred because upstream's *widget* sidebar hard-codes `Qt::AlignHCenter` in
`ProgressTreeDelegate.cpp` — C++ inside app-admin/calamares that no branding file can reach. The
QML flavour is different in exactly one way that matters here: `CalamaresWindow` loads it through
`Calamares::searchQmlFile(QmlSearch::Both, "calamares-sidebar")`, which looks in the branding
component directory **first**, so a `calamares-sidebar.qml` beside `branding.desc` replaces the
stock one by convention — no fork, no patch, no second thing to maintain.

So: `sidebar: qml` in `branding.desc.in` (the bottom navigation bar stays widget — it is fine),
and a `calamares-sidebar.qml` that is upstream v3.4.2's file with one change: the step label
loses `anchors.horizontalCenter` and gains `anchors.left: parent.left; anchors.leftMargin: 12`.
Everything else — the `Branding.styleString` colours (so the dark surface and the teal current
step are exactly the design tokens), the logo, the highlight pill — is stock. The stock file's
`qsTr("About")`/`qsTr("Debug")` share the sibling pages' lupdate limitation (plan/25 §4) and
render English; noted in the file, not fixed here.

## 6. Tests

`tests/test-installer.sh`:

- **§6e, rewritten gate assertions**: `nextEnabled()` gates on the disk alone; `isAtEnd()`
  returns `confirmed()` (so the window's Next asks instead of leaving); `next()` requests the
  confirmation; `onLeave()` publishes then re-arms; the QML carries the dialog and no checkbox;
  the disk-change clear stays pinned.
- **New**: `allowWeakPasswords` in both confs and read by the module; `passwordSettled()` in the
  `isAtEnd()` gate; `publish()` emits `autoLogin`; `imageidentity` honours GlobalStorage's
  `autoLogin`; `sidebar: qml` with a branding-owned `calamares-sidebar.qml` whose step text
  left-aligns with a margin, colours still from `styleString`.
- The structural python checks (every `disk.*` binding resolves; every `Q_PROPERTY` CONSTANT or
  notifying an emitted signal) keep running over the changed files; the new members
  (`selectedDiskTitle` → `currentIndexChanged`, the dialog's `Q_INVOKABLE`) are shaped to pass
  them.

## 7. Known limits

- **The two dialogs' own words are English in eight of nine languages**, like every other
  `qsTr()` on these pages (plan/25 §7): the builder's lupdate has no QML support. The disk
  dialog's *body* (`lossSummary`) and the password dialog's *warning* (`passwordMessage`) are
  C++ strings and translate; only the titles and buttons do not.
- **`Kirigami.PromptDialog` inside a `QQuickWidget`** is a first for this tree (the KCM
  precedent runs in a KCM shell). Dialog is Popup-based and overlays the widget's scene; if the
  medium shows it misbehaving, a plain `QQC2.Dialog` with the same content is the fallback.
- **The sidebar's font** follows the stock QML sidebar, which does not apply the widget flavour's
  +4 pt; if it reads thin at 900×600, the point size is a one-line addition to the copy.

## Changes to other documents

- `config/calamares/modules/accounts.conf.in` — the `doAutologin` paragraph rewritten for §4;
  `allowWeakPasswords` documented under `passwordRequirements`.
- `config/calamares/local-modules/imageidentity/main.py` — header item 1 and
  `write_autologin_dropin` describe both branches.
- `config/calamares/modules/imageidentity.conf.in` — `autologinDropIn` renamed to
  `20-autologin.conf`.
- `config/calamares/branding/installer/branding.desc.in` — `sidebar: qml`, with the reason.
