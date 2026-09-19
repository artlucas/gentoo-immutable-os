# The keyboard, the panel that said nothing, and four layouts that nearly fitted

Six requests against the installer's own pages, in one pass. They are not one feature, but they
share a medium and a build, and four of the six are layout changes that can only be judged at
1024×640 on a booted medium — so they travel together and are walked together.

> Installer profile, Calamares, custom modules. All custom modules: tab navigation should navigate
> between fields on page and cancel/back/next buttons. Visual cue should be given to show currently
> focused control. Welcome module: Panel to only show failing requirements or warnings. Do not show
> passing requirements. Hide panel completely if all requirements are passed. If panel is hidden,
> "This computer can install …" text should move up to where the panel used to be on the screen.
> Location module: add flag for 12-hr or 24-hr clock. Set to 12-hr clock by default. "Set date and
> time" modal should respect this flag (i.e., if 12-hr clock selected, show AM/PM drop down). Disk
> module: reduce vertical padding between disks in list. Several modules have scrollbars showing
> with only a few pixels overflow, adjust layouts to remove scrollbars where reasonably possible.
> Applications module: Note which desktop applications already come installed in the base image
> (Firefox, etc.). Remove inline scroll panel and let full page scroll.

## §1 The keyboard

### What was already true

More of this works than the ask implies, and knowing which half is which is what keeps the change
small. `Button.qml` has carried `activeFocusOnTab`, a 3px ring and `Keys.onSpacePressed` since
plan/28. Every `QQC2` control on these pages — the application tiles, the three mode cards, the
account chooser, the two `ComboBox` pickers — is tab-reachable already, because
`QQuickAbstractButtonPrivate::init()` calls `setActiveFocusOnTab(true)` and `QQuickComboBox` sets
`Qt::StrongFocus`. Those controls needed a better *cue*, not a focus chain.

### The finding that made the rest possible

The question that decides whether any of this can work is whether Tab escapes a `QQuickWidget` at
all: Calamares hosts the sidebar, the page and the navigation bar as three separate
`QQuickWidget`s (`CalamaresWindow.cpp`, `getQmlSidebar`/`getQmlNavigation`), and if Tab wrapped
inside each scene the navigation bar could never be reached from a page no matter what its buttons
declared. It does not wrap:

```cpp
// qtdeclarative/src/quickwidgets/qquickwidget.cpp:1536
bool QQuickWidget::focusNextPrevChild(bool next)
{
    auto *nextTarget = QQuickItemPrivate::nextPrevItemInTabFocusChain(currentTarget, next, false);
    // If no child to focus, behaves like its base class (QWidget)
    if (!nextTarget)
        return QWidget::focusNextPrevChild(next);
```

The third argument is `wrap`, and it is `false`. So a QML scene that has run out of focusable
items hands the focus back to the widget chain, and the widget chain is the window's. Making the
navigation bar's buttons focusable is therefore *sufficient*; no C++ in Calamares has to change,
and nothing has to be patched.

### The five gaps

1. **`Field.qml`** — the shared labelled input, and the whole of every account form. Its
   `TextInput` never set `activeFocusOnTab`, which defaults to **false** on a bare `TextInput`
   (unlike `QQC2.TextField`). Tab reached none of the account fields, nor either field of the
   set-time dialog.
2. **`calamares-navigation.qml`** — `NavButton` is a `Rectangle` with a `MouseArea`. Cancel, Back
   and Next were mouse-only. This is the finding reported at the end of plan/28 and never
   authorised until now.
3. **`calamares-sidebar.qml`** — About and Debug are the same shape and the same problem. Not in
   the ask; fixed anyway, because leaving two real controls off the chain while fixing the other
   nine is a decision nobody would defend out loud.
4. **The two hand-drawn check boxes** — `LocalForm.qml`'s "log in automatically" and `Done.qml`'s
   "restart now" are a `RowLayout` with a `TapHandler`. They carry the right `Accessible` role and
   the right toggle action and could not be reached or operated from the keyboard at all.
5. **The two views** — `Disk.qml`'s `ListView` and `Language.qml`'s `GridView`. `QQC2.ItemDelegate`
   sets `Qt::NoFocus` (`qquickitemdelegate.cpp:40`), so the rows are deliberately not individual
   tab stops; the *view* is the tab stop and the arrow keys move within it. Neither view set
   `activeFocusOnTab`, so neither was reachable — and the disk page's focus ring, which binds
   `row.visualFocus`, could never have shown, because a delegate with `NoFocus` never has it.

### The shared check box

Gap 4 appears twice, identically, and a third page would have copied it again. It becomes
`config/calamares/qml/CheckBox.qml`, beside `Theme.qml`, `Button.qml` and `Field.qml` — staged by
stage 20's fan-out, which is derived from each `CMakeLists.txt`, so naming `qml/CheckBox.qml` in
the two modules that need it is the whole of the delivery.

### The cue

One ring, everywhere, and it is the one `Button.qml` and `Field.qml` already draw: 3px, outside
the control's own box, `mix(accent, surfaceCard, 0.4)`. It goes on the controls that had only a
border change to say where the keyboard was — the two `Picker` combo boxes, the application tiles,
the three application mode cards, the account chooser cards, the network-time box — and on the five
gaps above. A border colour alone is not enough on a control that is *already* accent-bordered
because it is selected, which is the case a keyboard user meets on every one of these pages.

## §2 The Welcome panel

`greeting.conf` checks six things and requires three. Since plan/28 the page has drawn a row per
check with its own status — which was the right answer to the vendored widget it replaced, and the
wrong answer to the screen: on a machine that passes everything, the panel is six green rows
saying nothing, above the one sentence that matters.

So: **failures and warnings only, and no panel at all when there are none.**

- `GreetingConfig` gains a `QSortFilterProxyModel` over Calamares' `RequirementsModel`, filtering
  on the `Satisfied` role, exposed as `problems`; and `hasProblems`, which the panel's `visible`
  binds. The proxy is a member rather than a `new` per read, and it is re-filtered on the model's
  own reset — `addRequirementsList()` calls `beginResetModel()`, so a five-second re-check that
  clears the last failure has to collapse the panel, not merely empty it.
- The panel keeps its spinner state: before the first round there is nothing to filter and
  "nothing is wrong" is not yet true.
- When the panel goes, the verdict moves up. That is what a `ColumnLayout` does with a child whose
  `visible` is false, and the one thing needed is that the *verdict* stops being the last item and
  starts being followed by the filler that used to be the panel's `Layout.fillHeight`.

## §3 The 12-hour clock

`location.conf` gains `twelveHourClock: true`. It is not a `.in`: like `apps.conf`, there is no
build-time token in it, and a clock format is not a rebrand's business.

- `LocationConfig::clockTime()` stops asking `QLocale` for a `ShortFormat` and formats to the
  flag: `h:mm AP` or `HH:mm`.
- The dialog's `Time` field switches between `hh:mm` and `HH:mm`, and in 12-hour mode a third
  control appears beside the two — an AM/PM select, drawn as the page's own `Picker` is.
- **The meridiem crosses the boundary as an index, not as a string.** The labels are
  `QLocale().amText()` / `pmText()`, so they follow the language the user picked one page earlier —
  and a C++ side that parsed the string it had just handed out would be re-deriving, in one
  language, something it already knew. `applySystemTime( date, time, meridiem )` takes `-1` when
  the flag is off.
- The hint under the field and the parse error both said "24-hour clock" in so many words. Both
  become the flag's own sentence.

## §4 Disk, and the scrollbars

**Disk.** Row padding 16 → 10 top and bottom, card gutter 10 → 6. The row's content is a 16px
title over a 12px mono line; 16px of padding above and below that is the design system's card
padding applied to a list, and a list of cards is what the design system spaces at its *gutter*.

**The scrollbars.** Several pages overflow 640px by a few pixels — which is the worst amount to
overflow by, because the bar appears, takes 8px of width, reflows the content and is then almost
unusable. The page's own vertical rhythm is what pays: the content margin is 36 top and bottom
(`space8 + space1`, the design system's page padding), and at 640px in a window whose navigation
bar takes 72 of it there is no room for a 36px gutter at both ends of a page that also has a
heading, a lede and a panel.

This is the one part of the work that cannot be finished from the checkout. What lands here is the
structural half — the disk rows above, §5's removal of the applications page's inner scroller — and
the measurements come off the booted medium.

## §5 Applications

**The inner scroller goes.** The page is a heading, an offline note, three cards and a six-tile
grid, and the top two were pinned while the bottom two scrolled inside a box. The whole page
scrolls instead: one `ScrollView` filling the widget, the content inside it — the shape
`Accounts.qml` already uses, down to `contentWidth: availableWidth` and a `sheet` Item carrying the
margins, because `qqc2-desktop-style`'s `ScrollView` binds the four individual padding properties
and an assignment to the grouped `padding` loses to them silently.

**What is already installed.** The page offers six Flathub applications and says nothing about the
five the image already carries, so "Nothing extra" reads as "nothing" — on a machine that is about
to arrive with Firefox, Ark, KWrite, Okular and Gwenview on it, plus Dolphin, Konsole and
Spectacle built in.

A new `included:` list in `apps.conf`, read-only on the page, under its own eyebrow. It is a list
in the configuration and not a string in C++ because the page already reads its other list from
there and the two have to be edited together. **It cannot be allowed to drift from
`FLATPAK_PREINSTALL`**, which is the build fact it describes — so `tests/test-installer.sh`
asserts every id in `build.conf`'s `FLATPAK_PREINSTALL` appears in `included:`, and that no id
appears in both `included:` and `apps:`. The native applications (Dolphin, Konsole, Spectacle) are
in the list too and are not in `FLATPAK_PREINSTALL`; the test is one-directional for exactly that
reason.

## What the medium actually said

The first build was walked at 1024×640 in three passes: with a network, with `-nic none`, and once
more for the states that only appear deep in the flow. Four of the six requests were right first
time. Three things were not, and all three are the kind that cannot be seen from the checkout.

**`hh` is not a 12-hour hour on the way out.** `editTime()` formatted with `"hh:mm"` on the
strength of Qt's documentation — which reads *"the hour with a leading zero (00 to 23 **or** 01 to
12 **if AP/A/ap/a is used**)"*. There is no AM/PM marker in that format, by design, because the
meridiem is a separate control. So at 1:06 PM the dialog opened on **`13:06`** with **PM**
selected, and pressing Set would have been refused by this plan's own range check — for a value
the dialog had filled in itself. The card beside it read `1:06 PM` throughout, because the clock's
format *does* carry `AP`. `editTime()` composes the string from the converted hour now; the
constant is for parsing only. The morning pass had missed it: at 12:58 the two conventions agree.

**The summary table scrolled for one row.** Six decisions in a box sized for five and a sliver,
behind a twenty-pixel scrollbar, with the first of them — Language — hidden above the fold. That
is the same shape the applications page was asked to lose, so it loses it the same way: the page
scrolls as one page and the table is as tall as its rows.

**The page margin was one pixel too generous.** The accounts chooser drew a full-height scrollbar,
which is the "few pixels of overflow" complaint exactly. The mockup sets 36 down the page and every
page transcribed it; at the window this installer actually opens — 640 tall, 72 of it navigation
bar — a page has about 568px, and the three chooser cards wanted 567 of them plus 72 of margin. It
is `Theme.pageMarginV: 28` now, one token rather than eight edits, and the horizontal 44 is
untouched because that is the rhythm the eye reads the column by.

What the walk confirmed rather than corrected: Tab goes About → Cancel → Next → the page's own
controls and round again, with the ring on every stop and disabled buttons skipped; **Tab ×3 then
Return advanced Language → Welcome with no mouse at all**; Welcome is one line on a machine that
passes and one warning row on a machine with no network, with the verdict still saying it can
install; the clock reads `12:53 PM`; the dialog carries an AM/PM select that opens inside the modal
and is pre-filled from the current half of the day; the disk rows are tight and the page no longer
scrolls; and the applications page carries all eight chips with their Breeze icons and no inner
scroller.

One thing noted and not changed: a page with no controls of its own — Welcome is the only one —
still has a tab stop on its `QQuickWidget`, which shows no ring because there is nothing in the
scene to draw one on. That is `QQuickWidget`'s own `Qt::StrongFocus` policy and not reachable from
QML.

## Verification

1. `bash tests/run-tests.sh` — offline, and `test-installer.sh` grows with each phase.
2. `qmllint` on every changed page, out of the builder image (memory:
   `lint-installer-qml-with-qmllint`).
3. A clean build and a walk of all ten steps on a booted medium, at 1024×640, checking:
   Tab from the first field of a page through to Next and round; the ring visible on every stop;
   the Welcome panel absent on a machine that passes and present with only the failures on one
   that does not; the set-time dialog in both clock modes; and which pages still show a scrollbar.

## Working method

Branch `installer-focus-and-layout` off `installer-network-time`, directly in the repo. A commit
per phase, and the commit message says what was actually run.
