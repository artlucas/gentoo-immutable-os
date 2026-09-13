# 22 — The installer's language page

The first page of this installer asks, in English, whether the machine has enough disk — and then,
underneath a logo sized to fill whatever space is left over, offers to change the language.

That ordering is not a configuration mistake. `WelcomePage.cpp` inserts the requirements checker at
`welcome_text_idx + 1`, immediately below the welcome text and *above* the language row, and on a
machine that passes every check `ResultsListWidget::requirementsComplete()` deletes the results
list and puts `Branding::ProductWelcome` in its place with an expanding size policy. So the normal,
healthy case is the worst one: two sentences of English, a large logo, and a closed combo box at
the bottom reading "English (United States)".

Someone who cannot read those two sentences has one thing to find on that page, and it is the last
thing on it.

This document replaces the stock `welcome` module with `language`: a compiled view module of our
own, whose **first screen is the language list and nothing else**, and whose second screen is the
greeting and the requirements verdict, in the language just chosen.

A rendered mockup of every screen and state below — at the real 900×600 geometry, including the
Japanese and Russian plates — is published alongside this document.

> **Screen 2 is its own module since [plan/23](23-installer-greeting-page.md).** The two screens
> were right and the single view step was not: a view step is one entry in the sidebar, so the
> installer's first two questions appeared as one step called *Language* and every step after it was
> numbered one place early. Everything below about the LIST is current. Everything about the second
> screen — §1's right-hand sketch, §1a's `isAtBeginning()`/`isAtEnd()` wiring, and §3a's "this
> module owns the checks" — describes the `greeting` module now, which also swapped this page's
> verdict grid for the stock welcome module's requirements box. §9 is the two defects that were
> found in what is left behind.

## 1. What it looks like

Two screens in one view step. The same shape as the accounts page ([plan/21](21-installer-accounts-page.md) §1),
for the same reason and with the same wiring.

```
 screen 1                                    screen 2
 ┌────────────────────────────────────┐      ┌────────────────────────────────────┐
 │ 🌐  Language                        │      │ ▨ immos 0.3.0                      │
 │ ────────────────────────────────── │      │   Install medium                   │
 │  Deutsch                    German │      │                                    │
 │  English                   English │      │ This program will ask you a few    │
 │ ▓English (selected)        English▓│      │ questions and then install immos   │
 │  Español                   Spanish │      │ on this computer. Everything on    │
 │  Français                   French │  →   │ the disk you choose is erased.     │
 │  Italiano                  Italian │      │ ────────────────────────────────── │
 │  Português (Brasil)     Portuguese │      │ ✓ This computer can install immos. │
 │  Русский                   Russian │      │                                    │
 │  日本語                    Japanese │      │ ✓ Disk 476 GB   ! Power battery    │
 │  简体中文       Chinese (Simplified)│      │ ✓ Memory 16 GB  ! Network none     │
 │                                    │      │ ✓ Administrator ✓ Screen 1920×1080 │
 └────────────────────────────────────┘      └────────────────────────────────────┘
      ← Back   Next →                             ← Back   Next →
   disabled       to screen 2                  to screen 1    leaves the page
```

### 1a. The wiring is four functions Calamares already calls, and one it already has

`ViewManager::next()` calls `step->next()` instead of advancing whenever `isAtEnd()` is false, and
`ViewManager::back()` calls `step->back()` instead of leaving whenever `isAtBeginning()` is false.
Reporting the screen number from those two is the entire navigation, exactly as on the accounts
page — one module, one sidebar entry, one `setConfigurationMap()`.

The Back button on screen 1 needs no code at all, and this is worth stating because the obvious
implementation is wrong. Stock `WelcomeViewStep::isBackEnabled()` returns a flat `false`; copying
that would strand the user on screen 2. What is actually needed is `return true`, because
`ViewManager` already special-cases the first step:

```c++
// ViewManager.cpp:487
UPDATE_BUTTON_PROPERTY( backEnabled,
                        ( m_currentStep == 0 && m_steps.first()->isAtBeginning() )
                            ? false
                            : m_steps.at( m_currentStep )->isBackEnabled() );
```

First step, at its beginning → Back is disabled by the window. First step, second screen → Back is
enabled and returns to the list. Upstream's `false` was a workaround for having one screen.

### 1b. The header word is the only text on screen 1, and it is drawn in the highlighted language

"Language", then `Sprache`, then `Idioma`, then `言語`, changing as the highlight moves down the
list. It is feedback and a label at once.

Anything longer would be the one sentence on the page that the reader cannot read. There is no
explanatory paragraph, no product name and no logo on screen 1: a list of nine languages written in
those languages explains itself to everybody who can see it, and an English sentence above it
explains nothing to the people the screen exists for. The greeting has a screen of its own, one
Next away, where it will be in a language the reader picked.

### 1c. No flags, and the native name is the larger line

A flag names a country and not a language, and for three of the nine there is no defensible choice
at all — English, Spanish and Portuguese each have several. Flags also fail the one test that
matters here, which is being recognisable to somebody who is *looking for their own language*
rather than browsing: `Português (Brasil)` is unmistakable, and a small rectangle of green is a
guess.

So each row is two lines. The native name is 15.5px and the language's name *in the currently
selected language* is 12px underneath it — never a locale code, on either line. The second line is
what lets an English-speaking technician set the machine up for somebody else, and what lets a user
who has landed in the wrong language find their way back.

Selection is a highlighted row with an accent rail and a check, not a radio button. The accounts
chooser uses hand-built `RadioButton`s because it presents three alternatives to be *compared*
with one selected (plan/21 §1b); this is a list of nine to be *scanned* for one. Different job,
different control — and nine rows at 44px is 396px inside a 536px viewport, so there is no
scrollbar, no search field and no letter-jump to design.

## 2. The list, and why it has nine rows

### 2a. What the 82 actually render as — measured

Calamares ships 82 translations, compiled into the binary by `calamares_qrc_translations()`, so
stage 50's `/usr/share/locale` trim never touches them: all 82 genuinely work today. Every one of
them also renders as a native name — there is no raw locale code in the welcome combo, which is
worth recording because it is the opposite of what the reported symptom suggests (see §6).

That was measured rather than assumed. A probe replicating `Translation.cpp`'s label logic was
compiled against the builder image's own **Qt 6.11.1** and run over all 82 ids. The
`* <id> (<English>)` fallback for an empty `nativeLanguageName()` never fires. What it did find is
worse than a code, because it cannot be resolved by looking:

| ids | both render as | |
|---|---|---|
| `ja`, `ja-Hira` | 日本語 | **identical**, character for character |
| `zh`, `zh_CN` | 简体中文 | **identical**, and the two catalogues are not — `zh_CN` is complete, `zh` is not |
| `sr`, `sr@latin` | српски / srpski | the same language, and nothing says which script |
| `zh_TW`, `zh_HK` | 繁體中文 / 繁體中文 (中國香港特別行政區) | |

and a tail of strings Qt composes awkwardly: `American English`, `British English (United Kingdom)`,
`español de España`, `español de México (México)`, `português europeu (Portugal)`,
`français canadien (Canada)`.

**No page can fix this from the model it is given.** `TranslationsModel::roleNames()` exposes
exactly two roles, `label` and `englishLabel`; the locale id is a private `QStringList` with a
`localeIds()` accessor that is neither a property nor `Q_INVOKABLE`. For the two identical pairs
above, *both* roles collide, so even a relabelling table keyed on the pair cannot tell them apart —
it would have to dedupe by row ordinal, and the ordinal that survives decides whether the largest
language group on the list gets the complete catalogue or the incomplete one. That is the reason
§3 is a compiled module and not a QML file in the branding directory.

### 2b. Nine rows, because nine is what the machine can deliver

The picker offers exactly the languages the **installed machine** can speak. Two things have to be
true for a language to appear:

- its message catalogue survives stage 50's prune (`LOCALES_KEEP` today), so the installed desktop
  is translated, and
- a matching locale is compiled into the image's locale archive (`LOCALE_GEN` today), so
  `imageidentity` will actually write it into `/etc/locale.conf`.

Today the second condition is met by `en_US.UTF-8` and nothing else, which is the whole problem
this section exists to close: `imageidentity.target_has_locale()` checks the target's compiled
locales before writing, and warns and keeps English for every other choice. The installer therefore
offers 82 languages and delivers one. An installer that speaks Greek to somebody whose machine
will boot in English is a worse outcome than an installer that never offered Greek — it spends the
user's trust on the one page where they have no way to check.

So both conditions are met by construction, out of one table:

```
# config/languages.conf — the installer's picker, /etc/locale.gen, the catalogues stage 50
# keeps, and FLATPAK_LANGS. One file, four consumers, and the file's ORDER is the list's order.
#
# id    | locale       | shown as            | in English
de      | de_DE.UTF-8  | Deutsch             | German
en      | en_US.UTF-8  | English             | English
es      | es_ES.UTF-8  | Español             | Spanish
fr      | fr_FR.UTF-8  | Français            | French
it      | it_IT.UTF-8  | Italiano            | Italian
pt_BR   | pt_BR.UTF-8  | Português (Brasil)  | Portuguese (Brazil)
ru      | ru_RU.UTF-8  | Русский             | Russian
ja      | ja_JP.UTF-8  | 日本語               | Japanese
zh_CN   | zh_CN.UTF-8  | 简体中文             | Chinese (Simplified)
```

Column 3 is **ours**, not `QLocale::nativeLanguageName()`. Nine hand-written strings are cheaper
than explaining to a user why the Spanish row says España while the Portuguese row says Brasil, and
they remove the last mechanism by which a code could reach the screen. Column 4 is the label
translated per language, so it lives in the `.ts` files of §4 rather than in this table.

The order is the file's order, which means it is a decision somebody made rather than the output of
a collation that cannot sort Latin, Cyrillic and Han against each other in any way a user would
predict. Latin alphabetically, then Cyrillic, then CJK.

`build.conf` keeps `LOCALES_KEEP` and `LOCALE_GEN` as *derived* values pointing at this file, so
stage 40's `localedef` loop, stage 40's `FLATPAK_LANGS` (line 347) and stage 50's catalogue trim
(lines 144–155) all keep working unchanged. **Adding a language is one row and a rebuild** — no
lock re-resolve, because nothing here is a package.

### 2c. What the compiled locales cost: 6.9 MiB

Measured with `localedef --prefix` in the builder image rather than estimated:

| | locale-archive |
|---|---|
| `en_US.UTF-8` alone (today) | 2.9 MiB |
| all nine | 9.8 MiB |

6.9 MiB, uncompressed, on a read-only root, to stop the first page making a promise the last page
breaks. The message catalogues do not move at all: `LOCALES_KEEP` already names these nine.

## 3. Why a compiled module, and what it has to take over

Calamares accepts only `Interface::QtPlugin` for `Type::View` (`ModuleFactory.cpp:53`), which is
the same wall plan/18 §7.2, plan/19 §7.3 and plan/21 §2 all hit. The alternative that does *not*
need a new package is upstream's `welcomeq` with our QML in the branding directory, and it was
rejected on two grounds, both mechanical:

- **It cannot fix the list.** §2a: no locale id reaches QML, and two pairs collide in both roles.
- **It would break the accounts page.** `QmlViewStep::setConfigurationMap()` starts an asynchronous
  `QQmlComponent` the moment the module loads, and `ModuleManager::loadModules()` walks the
  sequence in order, so the first page's QML compiles before `AccountsViewStep`'s constructor runs.
  `QQuickStyle::setStyle()` is silently ignored once anything has imported Qt Quick Controls, and
  the page loses Breeze's colours, Breeze's metrics **and every icon** together — the exact failure
  plan/21 §1b measured and the exact warning it left behind for it.

The package is `distro-base/distro-calamares-language`, beside
`distro-calamares-accounts` in `config/portage/overlay`, and every line of that ebuild's reasoning
carries over: `DEPEND` on `app-admin/calamares` resolves against the **builder** root because
`ESYSROOT` is `/`; `set(INSTALL_CONFIG ON)` or the packaged `.conf` silently does not install;
`RDEPEND` names kirigami and qqc2-desktop-style even though no `#include` mentions them. It is in
`@installer` only, and it is **mandatory** for the same reason the accounts page is: an installer
whose first module is missing is an installer that starts on the timezone page.

**The module is called `language`, not `welcome`.** `calamares_add_plugin` installs into
`<libdir>/calamares/modules/<name>/`, so a module named `welcome` would collide file-for-file with
`app-admin/calamares`'s own and be blocked by Portage. The name is also the better one: every other
entry in this installer's sidebar names a thing you set — Location, Keyboard, Partitions, Accounts —
and "Welcome" was the only one that named a mood.

### 3a. The requirement checks come with it, including the one that has never run

Dropping `welcome` means owning `GeneralRequirements`. That is a smaller inheritance than its 517
lines suggest, because most of it is configuration parsing and strings, and because **one of the six
checks does not exist on this medium.**

The ebuild configures Calamares with `-DCMAKE_DISABLE_FIND_PACKAGE_LIBPARTED=ON`. That makes
`find_package(LIBPARTED)` fail in `src/modules/welcome/CMakeLists.txt`, which adds
`-DWITHOUT_LIBPARTED`, which reaches this:

```c++
// GeneralRequirements.cpp:357
#ifdef WITHOUT_LIBPARTED
    if ( m_entriesToCheck.contains( "storage" ) || m_entriesToRequire.contains( "storage" ) )
    {
        // Warn, but also drop the required bit because otherwise installation
        // will be impossible (because the check always returns false).
        cWarning() << "GeneralRequirements checks 'storage' but libparted is disabled.";
        m_entriesToCheck.removeAll( "storage" );
        m_entriesToRequire.removeAll( "storage" );
    }
#endif
```

`welcome.conf.in`'s `requiredStorage: 32.0` — the value whose comment carefully adds up the ESP,
both root slots and `/var`, and argues that a disk too small for the second slot produces a machine
that installs and can never update — has never been enforced. There is no storage row on the page
and nothing blocks Next. A 16 GB target reaches the partition step before anything notices.

So the six checks, reimplemented against public `libcalamares` API that the accounts page already
links:

| check | how | mandatory |
|---|---|---|
| `storage` | largest block device under `/sys/block`, excluding `loop*`, `ram*`, `zram*`, `sr*` **and the device holding `/`** — the same exclusion `PartUtils::getDevices( WritableOnly )` applies to the disk picker, so the page and the picker agree about what disks exist | **yes** |
| `ram` | `Calamares::System::instance()->getTotalMemoryB()` | **yes** |
| `root` | `geteuid() == 0` | **yes** |
| `power` | `/sys/class/power_supply` for a battery, then UPower's `OnBattery` over QDBus | no |
| `internet` | `Calamares::Network::Manager::instance()` against `internetCheckUrl` | no |
| `screen` | largest `QScreen::availableSize()` | no |

`internet` and `power` stay informational for the reasons `welcome.conf.in` already gives and which
nothing here changes: this medium carries its payload, so an offline install is a first-class path,
and refusing to install on battery is patronising. Those two comments move to `language.conf.in`
verbatim — the reasoning was never about which module read them.

The verdict is one sentence with the rows as evidence beneath it, in four states (checking / ready /
ready-with-caveats / blocked). Only a mandatory failure is red and only a mandatory failure
disables Next. `ModuleManager` already re-runs the checks every five seconds while a mandatory
requirement is unmet, so plugging in a bigger disk clears the page without restarting the installer.

### 3b. `QQuickStyle::setStyle` moves here

It is currently in `AccountsViewStep`'s constructor, behind a `QT_QUICK_CONTROLS_STYLE` environment
check, with a warning for the case where something loaded QML first (plan/21 §1b). This module is
that something — and being first in the sequence makes it the correct owner, not a new hazard. The
accounts page keeps its guard and its warning **unchanged**, where they become the canary for a
future module inserted before this one.

## 4. Our own pages, in the user's language

Leading with a language picker is a promise, and the page after next currently breaks it: the
accounts page — the only page in this installer with real decisions on it — uses `tr()` and
`qsTr()` with no translation files, so it is English in all 82 languages. So is everything this
document adds.

There is no fourth mechanism needed. Calamares installs a **branding translator** on
`QCoreApplication` and reloads it on every language change, from a path the branding component
already owns:

```c++
// Branding.cpp:296
QDir translationsDir( componentDir.filePath( "lang" ) );
m_translationsPathPrefix = translationsDir.absolutePath();
m_translationsPathPrefix.append( QString( "%1calamares-%2" ).arg( QDir::separator() ).arg( m_componentName ) );
```

→ `/etc/calamares/branding/installer/lang/calamares-installer_<lang>.qm`, loaded by
`BrandingLoader::tryLoad()` inside `installTranslator()`. A `QTranslator` installed on the
application resolves by `(context, sourceText)` regardless of which library the context lives in, so
our modules' contexts ride in that one file. No `QTranslator` of our own, no retranslation wiring,
no change to how the language switch works.

The sources are `config/calamares/branding/installer/lang/calamares-installer_<lang>.ts`, one per
row of §2b's table minus `en`. Stage 40 compiles them with `lrelease`, which is already on the
builder: `dev-qt/qttools:6[linguist]` is a `DEPEND` of the accounts ebuild and therefore installed
into the builder root.

**This is where the nine-row list pays for itself twice.** Eighty-two `.ts` files that nobody can
review is a worse lie than an English page; eight is a set a project this size can actually keep
honest. Stage 40 asserts that every row in `config/languages.conf` except `en` has a `.ts` file and
that `lrelease` produced a `.qm` for it — a missing translation must fail the build rather than
fall back silently to English on one page out of eight.

## 5. What moves

| | |
|---|---|
| `config/languages.conf` | **new.** §2b's table; the source of the picker, `/etc/locale.gen`, `LOCALES_KEEP` and `FLATPAK_LANGS` |
| `config/build.conf` | `LOCALE_GEN` and `LOCALES_KEEP` become derived from the table; the comments point at it |
| `scripts/lib/common.sh` | **new `load_languages()`**, called from `load_config()`: parses and validates the table, derives `LOCALE_GEN`/`LOCALES_KEEP`, and builds `INSTALLER_LANGUAGES` — the rendered `languages:` block. That last one belongs here rather than in stage 40 because stage 40 is not the only thing that renders the Calamares tree; `tests/test-installer.sh` renders all of it offline, and a token only the build stage defined made every one of those renders die |
| `scripts/lib/check-translations.py` | **new.** The translation rules, once, for two callers — stage 40 and `tests/test-installer.sh` |
| `scripts/update-translations.sh` | **new.** `lupdate` in the builder, to re-extract `<source>` strings after a code change. Deliberately not part of the build: a stage that rewrote repository files would paper over the one failure the check exists to catch |
| `config/portage/overlay/distro-base/distro-calamares-language/` | **new.** Ebuild + `files/`: `LanguageViewStep`, `LanguageConfig`, `Requirements`, and `qml/` |
| `config/portage/sets/installer` | adds `distro-base/distro-calamares-language`, mandatory, installer-only |
| `config/calamares/settings.conf.in` | `welcome` → `language` in the `show:` sequence |
| `config/calamares/modules/welcome.conf.in` | **deleted**; its requirements block and both of its "informational, not required" arguments move to `language.conf.in` — and on again to `greeting.conf.in` in [plan/23](23-installer-greeting-page.md) §3, with the arguments unchanged |
| `config/calamares/modules/language.conf.in` | **new.** The requirements block, plus the rendered language table. Since plan/23 it is the table alone, and stage 40 fails a build in which the block has come back |
| `config/calamares/modules/locale.conf` | gains `localeGenPath: /etc/locale.gen` — see §6 |
| `config/calamares/branding/installer/lang/*.ts` | **new.** Eight files. They carry the language page's five contexts, translated; the accounts page's are not extracted yet — see §8 |
| `scripts/stages/40-configure.sh` | renders the table into `language.conf` and `/etc/locale.gen`; runs `lrelease`; asserts the `language` module's `module.desc` exists, the way it already does for `accounts` |
| `scripts/stages/50-prune.sh` | catalogue trim reads the table instead of `LOCALES_KEEP` |
| `config/calamares/README.md` | the module map: `welcome` joins the replaced row; the "Locales" known limit is deleted, because §2 closes it |

The lock moves once, for one package: `scripts/relock.sh <id>-base/<id>-calamares-language --profile installer`.

## 6. The locale page, and where `en_CA` actually comes from

The welcome page shows no locale codes today (§2a). The **locale page** does, and it is worth being
precise about it because it is the next page the user sees.

`locale/Config.cpp:51` reads `/usr/share/i18n/SUPPORTED` first and only falls back to
`localeGenPath`. Nothing prunes `/usr/share/i18n`, so that file is on the medium and the page's
language dialog offers roughly five hundred entries — `en_CA.UTF-8` among them — of which exactly
one can be loaded by the machine being installed.

Two thirds of that is closed here, cheaply:

- stage 50 deletes `/usr/share/i18n/SUPPORTED` on the installer profile, and `locale.conf` names
  `localeGenPath: /etc/locale.gen`, which stage 40 writes from the same table. The dialog then
  lists exactly the nine locales the image compiled.
- the handoff already works and keeps working: this page writes GS `LANG` through
  `Calamares::Locale::insertGS` exactly as stock `welcome` did, and
  `locale/Config::automaticLocaleConfiguration()` reads it back and matches it against
  `supportedLocales()`. Restricting that list to nine is what makes the match land somewhere the
  target can load.

What is **not** closed is that `LCLocaleDialog` renders those nine as the strings `de_DE.UTF-8`,
`ja_JP.UTF-8` and so on. It is upstream's dialog, behind a button, and there is no configuration
that relabels it. Removing that last code means replacing the locale page too, and this document
does not: it is a separate module, a separate decision (timezone is the page's real subject), and
the nine strings behind a button are a much smaller wrong than the five hundred in front of it.
Recorded in §8 as the open question it is.

## 7. Tests

| | |
|---|---|
| `test-installer.sh` | `language` in the sequence and in the descriptor checks; `welcome` joins the *forbidden* list at line 304 with the same note `users` carries — it is the second entry there that would otherwise work; `modules/language.conf` is referenced; `welcome.conf` is gone |
| `test-installer.sh`, the table | every row of `config/languages.conf` has four non-empty fields, a unique id, a `.UTF-8` locale and a `.ts` file; the rendered `language.conf` has the same number of rows as the table; `/etc/locale.gen` has one line per row |
| `test-installer.sh`, the page | every `language.<name>` in the QML resolves to a declared `Q_PROPERTY` or method; every `Q_PROPERTY` is `CONSTANT` or notifies a signal **something actually emits**; the view step calls `engine()->retranslate()`. *(The screen-navigation assertions in this row moved to the greeting module with the screen — [plan/23](23-installer-greeting-page.md) §6 — and were replaced here by the selection assertions in §9.)* |
| `test-installer.sh`, the checks | `storage` in both `check:` and `required:`; the checker reads `/sys/block` itself; and **no preprocessor conditional on `LIBPARTED` anywhere in our sources** — the grep is on `#if`/`#ifdef` rather than on the token, because `Requirements.h` quotes upstream's hatch at length on purpose and an escape hatch you cannot find is how this stayed broken |
| `test-installer.sh`, the table | no label contains `_`, `@` or `.UTF-8`; no two rows share an id, a locale, a label or an English name; `en` is present. This is the §2a regression, expressed as a property |
| `test-installer.sh`, the set | `@installer` names exactly **three** atoms, and which three. **Four** since plan/23 |
| stage 40, after `localedef` | `locale -a` in the target contains every locale the table names, normalised exactly the way `imageidentity.target_has_locale()` normalises. **Moved here from stage 70**, which is where this table first put it: stage 40 is where the target is mounted and the archive was just written, and stage 70 boots a finished image and would be asserting the same fact one layer further from anything it could fix |
| stage 50 | `/usr/share/i18n/SUPPORTED` is absent from a live root, `/etc/locale.gen` is non-empty (the fallback is only useful if what it falls back to exists), and a `.qm` is present for every non-`en` row |

The two things that can only be checked by running the installer — that Back on screen 2 returns to
the list, and that the whole window retranslates on selection — are in exactly the position plan/21
§8 left the accounts page's navigation in, blocked on the same gap: stage 70 cannot drive Calamares
unattended (plan/16 §10, question 5). The mechanical assertions above are what hold them, and each
one closes a failure that compiles.

## 8. Known limits and open questions

- **The nine are all left-to-right.** Adding Arabic, Hebrew, Persian or Urdu flips the window
  through `QApplication::setLayoutDirection` — sidebar on the right, Back and Next reversed, every
  page in this installer affected. That is a layout to design and test, not a row to append to the
  table, and nothing in §2b's mechanism warns about it. Worth a guard in the table's validator.
- **Eleven rows is the limit of a list with no search.** At 44px a row, twelve rows overflow the
  536px viewport and the design needs a scroll affordance and probably a filter field. The table
  makes growing the list trivial; this note is the reason it should not be trivial.
- **`LCLocaleDialog` still shows nine locale codes** (§6). Closing it means replacing the locale
  page, which is a separate document.
- **Number and date formats follow the timezone, not the language.**
  `LocaleConfiguration::fromLanguageAndLocation` mixes the chosen language with the timezone's
  country, and with only nine locales to choose from it will sometimes have to fall back. A user in
  Poland choosing English gets `en_US.UTF-8` and American date formats. Correct behaviour for the
  locales available; surprising, and not something this page can fix.
- **The accounts page is still English in all eight languages.** The `.ts` files carry the
  language page's own contexts — `LanguageNames`, `LanguageConfig`, `LanguageViewStep`,
  `Requirements`, `Language` — and not the accounts page's, because those were never extracted.
  `scripts/update-translations.sh` is what closes it: one `lupdate` run pulls its ~60 strings in as
  `unfinished`, and somebody then translates them. Until that happens the fallback is correct
  behaviour rather than a defect — an untranslated message renders as its English source — but the
  promise the first screen makes is only two thirds kept.
- **The accounts page also needs one line of its own, and it is not in this change.** Its QML has
  no `engine()->retranslate()`, so once its strings *are* translated they would render in whichever
  language the installer started in — English, since the medium boots with no `LANG` — and never
  switch. The language page carries that line; the accounts page does not. It belongs with the
  version bump its translations will need anyway, for the reason in the box below.

> **There is no working recipe for BUMPING an in-repo overlay package, only for adding one**, and
> this change found it the expensive way. `config/portage/overlay/README.md` says: run stages 20
> and 30 for a VDB, then relock. That works when the lock simply *lacks* a package. It does not
> work when the lock *pins a version that no longer exists*: stage 20 refuses (correctly — the
> `.lock-missing` guard), `RELOCK=1` gets past that, and then stage 30 emerges `@locked-image`
> — which still names `=…-accounts-1.0` — and fails. Relock cannot run first, because it needs
> the VDB stage 30 would have produced.
>
> Measured rather than reasoned: `immos-calamares-accounts-1.0` has two cached binpkgs, so leaving
> the version alone and editing `files/` reuses one of them and the edit never reaches the image.
>
> The fix is small and belongs in its own change: stage 30 should drop `$CONFIG_ROOT/.lock-missing`
> atoms from the set when `RELOCK=1`, the same way `relock.sh` already composes `@relock-target`.
> Until then, a version bump and a new package cannot land in the same pass.
- **`check-translations.py` has a deliberate hole, in one direction.** It proves every string *in*
  the `.ts` files matches the code, and says nothing about strings in the code that are in no `.ts`
  file. That asymmetry is what lets the accounts page's gap exist without failing the build, and it
  is the reason the item above has to be tracked here rather than by the check.
- **The translations want a native review.** Eight languages' worth of short UI strings were
  written to ship the page, not by native speakers of all eight. They are wrong in the way
  first-draft translations are wrong — plausible and occasionally unidiomatic — and the `.ts` format
  is what makes a reviewer's pass cheap.

## 9. The selection that only ever pointed at row 0

Two defects, found by using the page rather than by reading it, and they are one property handled in
one direction. Both compile, both run, and both look like a working installer.

**The highlight never moved.** Whichever row you clicked, the first one stayed selected — while the
language actually changed, because the whole window retranslated around the highlight that had not.

The delegate is a `QQC2.ItemDelegate` inside a `ListView`, and its `highlighted:` binding reads
`ListView.isCurrentItem` — the **view's** `currentIndex`. Its `onClicked` wrote to
`language.currentIndex`, the C++ one. A `QQC2.ItemDelegate` does not touch its view's `currentIndex`
when clicked; nothing else did either; so the two numbers diverged the first time anybody used the
mouse. Arrow keys worked, because those are the one path that moves the view's own index — which is
also why this survived to a built medium.

**The default language was the first row, not English.** `LanguageConfig::setConfigurationMap()`
resolves the system locale, gets the C locale on a medium that boots with no `LANG`, falls back to
`indexOfId( "en" )` and selects English before the page is ever drawn. The installer opened in
German anyway.

`QQuickItemView::componentComplete()` is the other half. Read in the medium's own Qt — 6.11.1,
`src/quick/items/qquickitemview.cpp`, not from memory:

```cpp
if ( d->currentIndex < 0 && !d->currentIndexCleared )
    d->updateCurrent( 0 );
else
    d->updateCurrent( d->currentIndex );
```

The view selects row 0 for itself unless `currentIndex` was *explicitly* set to -1 — and
`setCurrentIndex()` assigns `currentIndexCleared = ( index == -1 )` **before** its early return on
an unchanged value, which is the detail that makes writing the default out loud do something:

```cpp
d->currentIndexCleared = ( index == -1 );
d->applyPendingChanges();
if ( index == d->currentIndex )
    return;
```

It was not written out. So the view chose row 0, `onCurrentIndexChanged` pushed that 0 into C++, and
`Component.onCompleted: list.currentIndex = language.currentIndex` then read back the 0 it had just
caused. German is simply what `config/languages.conf` lists first; the bug had no opinion about
languages at all.

There is one way to undo the fix without touching either line, and it is worth knowing about.
`QQuickItemViewPrivate::connectModel()` forces `setCurrentIndex( count > 0 ? 0 : -1 )` — but only
`if ( q->isComponentComplete() )`, i.e. only when the model is assigned *after* the component is
built. `languages` is a `CONSTANT` property and `model:` is a declared initial binding, so today
that branch never runs. Making the model reassignable would put row 0 back, from a file nobody
edited.

### 9a. The fix is one property, handled in both directions

The view's `currentIndex` is the page's single source of truth for the selection, because it is what
draws the highlight. Everything writes to it, and C++ is allowed to refuse:

```qml
currentIndex: -1
Component.onCompleted: list.currentIndex = language.currentIndex
onCurrentIndexChanged: language.currentIndex = list.currentIndex
Connections {
    target: language
    function onCurrentIndexChanged() { list.currentIndex = language.currentIndex; }
}
...
onClicked: list.currentIndex = row.index
```

Neither direction can be a binding. `ListView` assigns `currentIndex` itself on every arrow key,
which would break `currentIndex: language.currentIndex` permanently and leave the C++ side unable to
drive the highlight ever again — which is what the comment that used to sit there said, correctly,
while solving only half of the problem it described. The two imperative handlers cannot ring:
`LanguageConfig::setCurrentIndex()` returns without a signal when the value has not changed.

The `Connections` block is the direction that had no implementation at all, and it is not
speculative: `setCurrentIndex()` **drops** an index the model does not have, and without it the view
would go on highlighting a row the installer was not going to install, with nothing on screen to say
so.

### 9b. What is asserted now

Six greps, and each one names the failure it closes rather than the line it matches: a click moves
the view's index; **no** delegate writes the C++ index directly; the `ListView` clears its
`currentIndex`; the view is seeded from C++ on completion; a view-driven change is pushed back; and
C++ can drive the view back. Plus the C++ half: `indexOfId( QStringLiteral( "en" ) )` is the
fallback, never row 0.

They are greps because the alternative is a running Qt Quick engine, which is the same gap §7 ends
on. A grep that names a defect somebody actually shipped is worth more than the coverage it looks
like.

## Changes to other documents

- **[plan/23](23-installer-greeting-page.md)** — supersedes this document's second screen, and is
  where the greeting, the verdict and the six checks are described now.
- **[plan/16](16-installer.md) §5.3** — the module map's `welcome` row changes from **Keep** to
  **Replaced by `language`**, with the same shape of note the `users` row carries since plan/21: it
  was kept correctly for its time, and what broke it was a requirement it could not express, not a
  defect in it.
- **[plan/16](16-installer.md) §4.2** — "Keep CJK fonts in the installer profile" gains its real
  number: the list is nine languages, two of which are CJK, and `INCLUDE_CJK_FONTS=0` renders two
  of the nine rows as tofu on the page that exists to be read.
- **[plan/21](21-installer-accounts-page.md) §1b** — the `QQuickStyle` call moves to the module in
  §3b; the guard and the warning stay where they are, and their reason changes from "in case" to
  "this is the module it was written about".
- **[plan/06](06-pruning.md)** — `/usr/share/i18n/SUPPORTED` joins the installer-profile deletions
  (§6), and the locale-archive grows 6.9 MiB on every profile (§2c).
- **`config/calamares/README.md`** — the "Locales" entry under *Known limits (Phase A)* is deleted.
  It described exactly the gap §2 closes, and leaving it would be the documentation claiming a
  limitation the code no longer has.
