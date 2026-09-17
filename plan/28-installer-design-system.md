# 28 — The installer stops painting Breeze

Four plans built this installer's pages and none of them chose how it looks. plan/21 through
plan/25 each ended the same way: a page that asks the right question, styled from
`Kirigami.Theme` — which is to say from Breeze, which is to say from whichever Plasma theme the
live session happens to be running. The one branded surface was the sidebar, painted by four
`style:` keys in `branding.desc`, and the seam between it and the page beside it was the most
visible thing on the screen.

So somebody watches the boot splash — a mark composed at build time from the design system's own
tokens — and then spends ten minutes in a stock KDE application. This plan closes that.

The input is `Immos Installer.dc.html`, a complete handoff for all ten steps against the same
token files the splash already resolves (`config/branding/README.md` records both). Its step list
is **the installer's own**, one for one:

    Language · Welcome · Location · Keyboard · Disk · Account · Applications · Summary · Install · Finish

and its Account step even has the picker → detail shape `AccountsViewStep` already implements. So
this is not a redesign of the flow. It is: every page paints the design system, and the four steps
still owned by upstream stop being a second design.

## 1. One token object, nine copies, no second install path

`config/calamares/qml/Theme.qml` is the design system transcribed into a plain `QtObject`: the
light palette with the teal accent, the 4px spacing grid, the radius and type scales, the motion
durations, and the two values CSS computes with `color-mix` that QML has no operator for. Beside
it are `Field.qml` and `Button.qml` — the two controls that had to be drawn rather than styled.

**It is not installed anywhere.** Every Calamares view module compiles its QML into its own `.so`
as a Qt resource, and each of their `CMakeLists.txt` carries a paragraph about why: a shared QML
module under `/usr/lib64/qt6/qml` is a second install path and a second search order, and a page
that renders blank if either is wrong, with nothing in the log. A resource cannot be
half-installed. So the sharing happens at **build** time — stage 20 copies each file from
`config/calamares/qml/` into the rendered `files/qml/` of every module whose `CMakeLists` names
it, and stage 40 copies `Theme.qml` once more into the branding component, for the two window
panels that belong to no module and have no resource at all.

The fan-out list is **derived from the build files**, not kept beside them: naming the file is the
opt-in, so a module added later is covered by the line it had to write anyway. What that cannot
catch — a module that *should* name one and does not — is a property of the checkout rather than
of the build, and `tests/test-installer.sh` checks it.

`Theme` is not a QML singleton, and the reason is the same one: a singleton needs a `qmldir`
beside it *and* an import path registered on the engine, which is the second search order arriving
by a different door. Each page owns one instead — `readonly property Theme ds: Theme {}` — and
hands `root.ds` down, qualified.

### Three findings that would have shipped in silence

- **`Kirigami.Theme.Custom` does not exist.** The `ColorSet` enum is
  View/Window/Button/Selection/Tooltip/Complementary/Header. The first repaint set
  `colorSet: Kirigami.Theme.Custom` on two pages; it evaluated to `undefined`, was assigned
  without complaint, and would have rendered both pages perfectly in the wrong palette.
  `qmllint` found it, which is why `tests/test-installer.sh` §6i now runs `qmllint` in the builder
  image over every installer `.qml` — skipping when there is no builder image, the same bargain
  the YAML pass makes with PyYAML. `inherit: false` and nothing else is the switch.
- **`ds: ds` binds a child's property to itself.** The right-hand side resolves in the *child's*
  scope, where the child's own `ds` shadows the page's: a binding loop, an undefined theme, and a
  page drawn in whatever `null` evaluates to. Hence the page owning the object.
- **A `// qmllint …` comment is a directive, not a comment.**

## 2. The pages

Layout scaffolding and every piece of selection logic stayed. Those are what plan/21–27 argued
for, and what the test suite pins; what changed is every colour, radius, size and gap.

- **Language** takes the handoff's heading and lede and its two-column grid — which **overrides**
  two decisions this repo argued at length (no English prose above a language picker; never a
  locale code). The file records the override rather than quietly dropping the old text. What
  survived of the old argument is the part that could be kept: both strings retranslate as the
  highlight moves, so they are never stuck in a language the reader did not choose.
- **Disk** was already closest to the handoff — it had the radio-dot rows, the to-scale layout bar
  with its legend, and the erase dialog. It needed paint, a mono `node · size · contents` line,
  and a badge that finally says out loud why the install medium is greyed out.
- **Apps** and **Accounts** turn their radio rows into cards where the card **is** the control:
  `background`, `indicator` and `contentItem` all replaced, so the words are inside the hit area,
  the keyboard target and the accessible object. That is plan/27 §7's finding taken one step
  further — a label beside a bare radio needed a `MouseArea` to be clickable, and a label inside
  the control needs nothing.
- **The account forms** left `Kirigami.FormLayout` behind. It puts labels to the left in a column
  as wide as the longest one, and gives every child its own row — which is what put a password's
  error message a row away from the field it answered, and cost plan/27 §6 a fix that had to be
  remembered at every new field. `Field` carries label, value, error and hint as one object, so
  there is no layout left that could separate them.
- **Greeting** stopped being a `QWidget`, and three vendored files went with it. plan/23 §2 took
  the copy of Calamares' `checker/` as the lesser evil because "no header of theirs is installed"
  — which was never true of `RequirementsModel`, whose header **is** installed. A QML `ListView`
  binds it directly, so the page lists every check with its own status instead of failures only:
  six checks run, three of them block, and a box that showed nothing when all six passed could not
  say which was which.

## 3. Light, and what light costs

The design system ships a light `:root` palette and a `[data-theme="dark"]` override. The
installer is **light**; the boot splash stays dark, because a firmware-time splash is dark.

That splits something that used to be whole. `logo.png` and `slide.png` are **pre-composited
pixels**, flattened onto a ground so they have no visible edge against the surface they are pasted
on — and `branding.desc`'s oldest comment promises exactly that. On a pale sidebar a block
flattened onto `#0a0d11` is a dark rectangle. So `make-splash-assets.py` grew a `--bg` argument
for `--logo` and `--slide`; it **defaults to the dark ground**, because `build_slide()` has a
second caller (the Plasma splash's preview for System Settings) that belongs to the dark theme,
and stage 40 passes the light value once, at the installer's own invocation.

The claim in `config/branding/README.md` is now precise: one *layout* function, two *grounds*.
That colour appears in three places — `Theme.qml`, `branding.desc`, and stage 40's
`INSTALLER_SURFACE_PAGE` — and the offline suite compares all three, because a disagreement
between the first two is a mismatched rail and a disagreement with the third is a logo with a
rectangle round it.

**And then the test found the part that had been missed.** `wordmark.svg` fills its glyphs with
`#f6f7f9` — `--text-strong` of the *dark* theme, because that was every consumer's ground when it
was outlined by hand. Flattened onto the light `--surface-page` it is the ground, so the logo
became a logomark with a blank space under it: right size, right position, no wordmark, and
nothing in the build to say so. The assertion that caught it compares the bounding box of
everything that is *not* the ground, on both grounds, and requires them equal — a shape the
handoff never had to state because it was true by accident until light broke it. `--ink` is now
the paired argument, `recolour()` swaps the RGB and keeps the alpha so no glyph edge moves, and
the generator refuses outright when ink and ground are the same colour. The slabs needed nothing:
they are the teal `--accent` and read on both.

## 4. The chrome

Both window panels are QML now. The sidebar already was (plan/26 §5, for the centred step names);
the navigation bar was widget on the grounds that it "was never the problem", and it is one now
for the same reason the sidebar was — a widget bar draws Breeze's buttons in Breeze's metrics
along the bottom of nine pages that draw the design system's. `calamares-navigation.qml` is
upstream's sample with its three `Button`s redrawn, and with Quit moved away from Next: upstream
puts all three at the right end, which makes "leave without installing" the neighbour of a button
that, on the summary page, writes to somebody's disk.

`windowSize` went from 900×600 to 1024×640. The handoff's pages are two- and three-column grids
and none of them had the room; 1024 is also the floor the `screen` requirement already checks
for, so this cannot ask for a window wider than a medium the greeting page will install from.

What no QML reaches — the exec step's progress page, the error dialog, Calamares' own About box —
resolves through `KColorScheme`, so `config/plasma/colors-installer.in` is appended to
`/etc/xdg/kdeglobals` **on this profile only**. The product image never gets it: its user picks a
scheme in System Settings, and an image shipping a hard-coded palette in `/etc/xdg` would be
overriding a choice that is not the distribution's to make.

## 5. The typeface

`media-fonts/ibm-plex` is the seventh atom in `@installer` and the first that is not a module.
The pages ask for "IBM Plex Sans" and "IBM Plex Mono" **by name**, and a family fontconfig cannot
resolve is substituted in silence — the installer renders and simply stops looking like the
design, which no assertion downstream could catch. The atom is the assertion.

**Archivo, the design system's display face, is not packaged in Gentoo at all.** The only Archivo
in this repository is the wordmark in `config/branding/wordmark.svg`, outlined once by hand
precisely so the build needs no font binary. Adding a font package with a network `SRC_URI` for
the sake of nine headings was weighed and refused: `fontDisplay` is IBM Plex Sans and weight
carries the emphasis. The substitution is recorded in `Theme.qml` and in
`config/branding/README.md` rather than left for the next reader to discover.

Stage 50 §3n cuts the atom down: the package ships twelve families and this image renders two, so
roughly 150 MiB of Serif, Condensed, variable, Arabic, Devanagari, Hebrew, Korean and two Thai
faces is dropped. The rule is stated **positively** — everything that is not `IBMPlexSans-*` or
`IBMPlexMono-*` goes — because a drop-list silently stops matching the day upstream adds a
thirteenth script, while a keep-list can only fail in the direction that is loud.

## 6. What this plan did not do

The four steps still owned by upstream — `locale`, `keyboard`, `summary`, `finished` — are
**recoloured, not rebuilt**. They follow the palette in §4 and nothing else; their structure is
still Calamares'. Replacing them means four new view modules and two new job modules, and
`config/calamares/modules/locale.conf` has been asking for the first of those since plan/22 §8:

> *"removing the last of them means replacing this page — a separate module and a separate
> decision, since timezone is what this page is really for."*

The groundwork is in place for it. `libcalamares/locale/TimeZone.h` exports `RegionsModel`,
`ZonesModel` and `RegionalZonesModel`, and `locale/Global.h` exports the `insertGS()` that writes
the `localeConf` map `imageidentity` already consumes — so a custom location page needs no tzdata
parsing. `ViewManager.h` and `viewpages/ViewStep.h` are installed, so a custom summary page can
read the preceding steps' `prettyStatus()`. The keyboard page is the hard one: layout and variant
enumeration is **not** in libcalamares, so it would mean vendoring
`keyboardwidget/keyboardglobal.{cpp,h}` — the bargain this plan just finished unwinding for the
greeting page.

The Install step stays upstream's `ExecutionViewStep`, which the branding slideshow already
covers.

## 7. Verification

`tests/run-tests.sh` is the gate, and it grew with the work rather than around it: 657 assertions
in `test-installer` (from 591), including the `qmllint` pass, the per-page sweep for
`Kirigami.Theme.inherit: false`, the ban on `qsTr()` in any installer QML, the three-way colour
comparison in §3, and a check that every colour literal in `Theme.qml` appears in
`config/branding/README.md`.

**What no offline test can see is the thing this plan is about.** A page that misses
`inherit: false` renders perfectly, in the wrong palette, with nothing in the log. The per-page
sweep catches the omission; it cannot catch a token used where another was meant. Boot the medium
and walk all ten steps — the sidebar, the erase dialog, the About box, the progress page and its
slide, and a non-English run, because the sidebar and navigation retranslation paths have a
history of going stale.
