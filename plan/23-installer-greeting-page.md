# 23 — The greeting gets a module of its own

[plan/22](22-installer-language-page.md) put the language list first and the greeting behind it, as
two screens of one Calamares view step. The screens were right. The step was not.

A view step is **one entry in the sidebar**. So an installer whose first two questions were "which
language" and "may we erase this disk" showed one step called *Language*, the greeting had no row
of its own, and every step after it was numbered one place early for the rest of the install. The
sidebar is the only thing on screen that says how much is left; it was wrong from the first page.

This document splits the second screen out into `greeting`, a second compiled view module, and
takes the six requirement checks with it. It also fixes two defects in what is left behind — see
[plan/22 §9](22-installer-language-page.md#9-the-selection-that-only-ever-pointed-at-row-0), where
they belong, because they were never about the greeting.

## 1. What it looks like

One screen, and most of it is a box this project did not draw.

```
 ┌──────────────────────────────────────────────┐   while checking
 │ immos 0.3.0                                  │
 │ Install medium                               │
 │                                              │
 │ This program will ask you a few questions and │
 │ then install immos on this computer. Every-   │
 │ thing already on the disk you choose will be  │
 │ erased.                                      │
 │                                              │
 │            ⟳  Gathering system information…   │
 └──────────────────────────────────────────────┘
        ← Back            Next →  (disabled)

 ┌──────────────────────────────────────────────┐   a mandatory check failed
 │ …                                            │
 │ This computer cannot install immos 0.3.0.  ⟳ │
 │  ✖  Disk — 12.0 GiB available, 32.0 GiB needed│
 │  !  Network — not connected, not required     │
 └──────────────────────────────────────────────┘
        ← Back            Next →  (disabled)

 ┌──────────────────────────────────────────────┐   everything passes
 │ …                                            │
 │        This computer can install immos 0.3.0. │
 │                                              │
 │                    ▨                          │
 │                 (logo)                        │
 └──────────────────────────────────────────────┘
        ← Back            Next →
```

Three things in that sketch are decisions rather than description.

**There is no logo in the header.** `ResultsListWidget::requirementsComplete()` deletes the results
list and puts `Branding::ProductWelcome` in its place, with an expanding size policy, the moment
every requirement is satisfied — so on a healthy machine the logo is already the bottom two thirds
of the page. A logo above it as well would be the "logo sized to fill whatever space is left over"
that plan/22 opened by complaining about.

**Back is enabled, and that is the one line upstream gets wrong for us.**
`WelcomeViewStep::isBackEnabled()` returns a flat `false`, correctly, because upstream's welcome
page is the first step and has nowhere to go. Ours has the language list behind it. Copying that
`false` strands somebody who picked the wrong language on the one page they cannot read, and it
compiles.

**Next is the installer's first real gate.** It is disabled until the mandatory checks pass —
`storage`, `ram`, `root` — and stays disabled while they do not. `internet` and `power` are checked
and reported and block nothing, because this medium carries its own payload and a laptop on battery
is nobody's business.

### 1a. Two verdict states, where upstream has four

Upstream's `Config::retranslate()` writes one of four sentences, and two of them are about
recommendations rather than requirements: *"does not satisfy some of the recommended requirements …
Installation can continue, but some features might be disabled."*

That sentence would be a lie on this medium. The only non-mandatory checks are `internet`, `power`
and `screen`, and nothing whatsoever is disabled by installing this image offline — the root
filesystem, the UKI and the Flatpak store all travel on the stick, which is what
`INSTALLER_PAYLOAD_FLATPAKS` and the whole of stage 90 exist for. So `GreetingConfig` keeps the two
sentences plan/22 wrote, *this computer can* and *this computer cannot install %1*, and the coloured
rows underneath say which item is a blocker and which is a note. Red for a failed mandatory check,
amber for a failed optional one; that colouring is upstream's `ResultDelegate` and needed no change.

## 2. The box is vendored, not redrawn

`CheckerContainer`, `ResultsListWidget` and `ResultDelegate` are copied from
`src/modules/welcome/checker/` of the Calamares 3.4.2 tarball into
`config/portage/overlay/distro-base/distro-calamares-greeting/files/checker/`, under the same
GPL-3-or-later they already carried.

Copying is not the aesthetic choice here; it is the only one. Those three classes are **private to
upstream's welcome module**: they are not in `libcalamaresui`, no header of theirs is installed by
`make install`, and `calamares_add_plugin` links a module against `Calamares::calamares` and
`Calamares::calamaresui` and nothing else. A module that wants the box carries the source or draws
its own.

**The edit is one rename.** Upstream's box takes a `Config*` — the welcome module's config class —
and calls exactly three things on it: `warningMessage()`, `requirementsModel()` and
`unsatisfiedRequirements()`, plus one signal, `warningMessageChanged()`. `GreetingConfig` is those
four and nothing else, and `Config` is spelled `GreetingConfig` in the vendored files. That is the
whole diff, and it is the point: the next time Calamares moves, the three-way diff against a fresh
copy is a provenance header and a rename rather than an archaeology exercise. Each file says so at
the top, and `tests/test-installer.sh` asserts that it still does.

`GreetingConfig.h` includes `modulesystem/RequirementsModel.h` rather than forward-declaring it, for
the same reason: `checker/CheckerContainer.cpp` reaches through that header for the complete type,
exactly as it reached through upstream's `Config.h`, and a forward declaration here would mean
editing a second vendored file.

### 2a. What it buys, and one thing it costs

The box knows things our verdict grid did not. It lists **only the failures**, so a healthy machine
reads as one sentence and a logo instead of six green ticks nobody needed to check; it keeps a
countdown running while a mandatory requirement is unmet and stops it when one is not; and it
replaces itself with the branding image when the news is good. All of that is behaviour every
Calamares installer already has, which is the argument for having it here too.

What it costs is the two-column grid plan/22 §1 drew, and with it the `Requirements::Check` struct
whose label/detail split existed to feed that grid. `Requirements` now builds
`Calamares::RequirementEntry` directly and has no second, structured accessor — the label and the
detail are still kept apart until the last moment and joined with an em dash, because "Disk" is what
a reader scans the column for and "12.0 GiB available, 32.0 GiB needed" is the evidence under it.

### 2b. Three of the strings are upstream's, and their translations are too

`Gathering system information…`, `Checking requirements again in a few seconds…` and the sidebar's
`Welcome` are Calamares' own strings in Calamares' own contexts, already translated into all nine of
our languages by people who translate Calamares. Those translations are lifted into
`config/calamares/branding/installer/lang/*.ts` rather than written again.

They have to be lifted rather than simply inherited, and the reason is an upstream bug worth
recording: `lang/calamares_*.ts` keys those two messages to a source ending in three ASCII dots
while the code that ships says `…`. Qt does not report a source mismatch — it returns the source
string. Checked rather than assumed: across all eight catalogues this medium loads, **neither
message exists in the ellipsis form at all**, so both of those strings are English in every one of
our languages in a stock Calamares 3.4.2. Our catalogue carries the ellipsis form with upstream's
translation attached, which fixes them for this medium and for nobody else.

## 3. The checks move with the page

A requirement is contributed by a **module** (`Module::checkRequirements`), so the module that draws
the verdict is the module that must own the checks. `Requirements.{h,cpp}` moves from the language
module to this one unchanged apart from its log prefix, and the `requirements:` block moves from
`modules/language.conf` to a new `modules/greeting.conf` with it.

Everything [plan/22 §3a](22-installer-language-page.md#3a-the-requirement-checks-come-with-it-including-the-one-that-has-never-run)
argued about that block still holds, including the part that matters most: `requiredStorage: 32.0`
was discarded at startup for the whole life of the stock welcome module, because
`-DCMAKE_DISABLE_FIND_PACKAGE_LIBPARTED=ON` reaches `GeneralRequirements.cpp:357` and that function
deletes `storage` from both lists with nothing but a `cWarning`. Our checker measures `/sys/block`
itself and carries no preprocessor conditional at all. Both facts are asserted, on the new path.

`language.conf` is left with one key, which is the right shape for a page that asks one question —
and stage 40 now fails a build whose `language.conf` still carries a `requirements:` block, because
a second copy of the disk size that nothing reads is worse than none.

## 4. Why it is called `greeting`

`calamares_add_plugin` installs a viewmodule into `<libdir>/calamares/modules/<name>/`, so a plugin
called `welcome` collides file-for-file with `app-admin/calamares`' own and Portage blocks the
merge. That much plan/22 already knew.

The second reason is worse than a blocked merge. `ModuleManager::doInit()` walks `modules-search` in
order and keeps the **first** `module.desc` it finds for a given name, silently:

```cpp
if ( ok && !moduleName.isEmpty() && ( moduleName == currentDir.dirName() )
     && !m_availableDescriptorsByModuleName.contains( moduleName ) )
```

So two modules named `welcome` would resolve by the order of a list in `settings.conf`, with no log
line saying which one won. The directory, the `module.desc` name and the `settings.conf` entry are
all `greeting`; `GreetingViewStep::prettyName()` returns `tr( "Welcome" )`, because the sidebar is
for readers and the filename is not.

## 5. What moves

| | |
|---|---|
| `config/portage/overlay/distro-base/distro-calamares-greeting/` | **new.** Ebuild + `files/`: `GreetingViewStep`, `GreetingConfig`, `GreetingPage`, `Requirements` (moved), and `checker/` (vendored) |
| `…/distro-calamares-language/files/Requirements.{h,cpp}` | **moved** to the greeting module; `Check`/`checks()` dropped with the grid that read them |
| `…/distro-calamares-language/files/LanguageViewStep.{h,cpp}` | loses `checkRequirements()`, `back()`, `next()`, and the two screen reports; `isAtBeginning()`/`isAtEnd()` are `true` |
| `…/distro-calamares-language/files/LanguageConfig.{h,cpp}` | loses the `Screen` enum, the verdict, the greeting strings and the requirements model — the pair goes from 634 lines to 418 |
| `…/distro-calamares-language/files/qml/Language.qml` | screen 2 deleted; the selection rewired (plan/22 §9) |
| `config/portage/sets/installer` | adds `distro-base/distro-calamares-greeting`, mandatory, installer-only. The set's asserted count goes 3 → 4 |
| `config/calamares/settings.conf.in` | `greeting` in the `show:` sequence, immediately after `language` |
| `config/calamares/modules/greeting.conf.in` | **new.** The requirements block, moved out of `language.conf.in` verbatim |
| `config/calamares/modules/language.conf.in` | down to the rendered language table and nothing else |
| `config/calamares/branding/installer/lang/*.ts` | four strings change context; three upstream contexts arrive with upstream's translations (§2b) |
| `scripts/lib/check-translations.py` | scans `checker/`; **new check 5** — every context's strings must live in the file that context names |
| `scripts/update-translations.sh` | the greeting module joins the `lupdate` source list |
| `scripts/stages/40-configure.sh` | asserts the `greeting` module is installed, is the second `show:` entry and declares `type: viewmodule`; asserts `greeting.conf` carries the requirement keys and `language.conf` does not |

The lock moves once, for one package:
`scripts/relock.sh <id>-base/<id>-calamares-greeting --profile installer`.

## 6. Tests

| | |
|---|---|
| `test-installer.sh`, the sequence | `greeting` is the **second** `show:` entry — not for `QQuickStyle`'s reason, but because everything on the page is drawn in the language the page before it chose |
| `test-installer.sh`, the config | `greeting.conf` sets `requiredStorage`, `requiredRam`, `internetCheckUrl`, and names `storage`/`ram`/`root` in **both** lists; `language.conf` carries no `requirements:` block at all |
| `test-installer.sh`, the step | `isNextEnabled()` reads `satisfiedMandatory()`; `satisfiedMandatoryChanged` is connected, or a bigger disk clears nothing; `isBackEnabled()` returns `true` and not stock welcome's `false`; the module contributes the checks; the module does **not** call `QQuickStyle::setStyle` |
| `test-installer.sh`, the vendored files | each of the six says where it was vendored from; none still includes upstream's `Config.h`; `GreetingConfig` still declares the three methods the box calls |
| `test-installer.sh`, the page | it draws no logo of its own (§1) |
| `test-installer.sh`, what is left behind | the language step reports no screen and contributes no requirements, and no `Requirements.*` is left in its directory |
| `test-managed.sh` | the overlay renders exactly **four** ebuilds |
| `check-translations.py` check 5 | every context names a source file, and every string in a context appears in the file that context names — which is the check that would have caught this split's most likely mistake |

The things that can only be seen by running the installer are unchanged from plan/22 §7 and blocked
on the same gap: stage 70 cannot drive Calamares unattended. Everything above closes a failure that
compiles.

## 7. Known limits

- **The removal of the second screen removes a keyboard path.** On the old page, Back from the
  greeting returned to the list without leaving the module. It still does — `isBackEnabled()` is
  `true` — but it is now a step transition, so the sidebar highlight moves and the window repaints.
  That is the correct behaviour for two steps and worth noticing as a change.
- **`GreetingPage` is the only widget page this project wrote.** The language and accounts pages are
  QML in a `QQuickWidget`; this one is Qt Widgets, because the box it exists to host is. Five of
  the installer's eight pages are already widgets, so it matches the majority — but it does mean two
  styling systems in one installer, and a future Kirigami restyle would have to decide what to do
  about it.
- **Upstream's countdown widget has no accessible name.** `CountdownWaitingWidget` is a painted
  spinner with a tooltip; a screen reader gets nothing from it. Inherited, not introduced, and the
  verdict sentence beside it carries the same information in text.
- **The `it` row does not get a translated Calamares.** Not this document's change, and reported
  separately: `config/languages.conf` spells Italian `it` while upstream ships `calamares_it_IT.qm`,
  and `QTranslator::load` strips suffixes rather than adding them. Our branding strings are Italian;
  every stock page is English.

## Changes to other documents

- **[plan/22](22-installer-language-page.md)** — §1's two-screen sketch, §1a's four-function wiring
  and §3a's "this module owns the checks" now describe two modules. The document gains §9 for the
  two selection defects, which were always about the page it describes.
- **[plan/16](16-installer.md) §5.3** — the module map's `welcome` row already read *Replaced by
  `language`*; it becomes *Replaced by `language` + `greeting`*, and the requirements box is noted
  as borrowed rather than rewritten.
- **`config/calamares/README.md`** — the module map gains the `greeting` row.
