# plan/31 — the sidebar that truncates, and three defaults that were already decided

Four reports off the second build of plan/30, all of them things the checkout looks right about
and the screen disagrees with.

    1. The set-time dialog's AM/PM select sits lower than the Date and Time fields beside it.
    2. Some languages truncate the sidebar's step names.
    3. The accounts chooser opens with no card selected, though "Local accounts only" is the
       mode the page is already in.
    4. Every row in the Welcome panel wears an exclamation chip, and so does the verdict under
       it, so the one line that says whether the install can happen shares its mark with six
       lines that are only explaining themselves.

## §1 The AM/PM select, and what a GridLayout does with a row it has stretched

`Location.qml`'s set-time dialog is a three-column `GridLayout`: `Field` (Date), `Field` (Time),
`Picker` (AM/PM). A Field is a label over a 40px box over a hint; the Picker is a label over a
40px box and nothing else. So the row's height is the Field's, and the Picker is the short child.

What happens next is the part that is not obvious from reading the file. `Layout.fillHeight`
**defaults to true for a layout item** — `RowLayout`, `ColumnLayout`, `GridLayout` — and both
Field and Picker are `ColumnLayout`s. So the Picker is stretched to the full row height, and a
`ColumnLayout` given more height than its children ask for distributes the surplus *between* them.
The measured result at 1:43pm: the Date label at y=163 with its box at 183 (a 20px gap), the AM/PM
label at y=171 with its box at 203 (a 32px gap). Both the label and the box moved, and they moved
by different amounts, which is why this reads as "lower" rather than "misaligned by n".

The fix is to stop the stretch rather than to compensate for it: `Layout.fillHeight: false` and
`Layout.alignment: Qt.AlignTop` on all three cells. All three then sit at their implicit height
with their tops level, and since Field and Picker share `ds.space2` between label and box and
`ds.controlHeightMd` for the box, the labels agree and the boxes agree. The hints hang below the
row, which is where a hint belongs.

It is all three and not just the Picker because two Fields whose hints wrap to a different number
of lines have the same disagreement waiting in them — today both hints wrap to two lines and the
two boxes happen to line up.

## §2 The sidebar is 168px because Calamares says so

`CalamaresWindow.cpp:503` builds the sidebar with

    qBound( 100, Calamares::defaultFontHeight() * 12, w < windowPreferredWidth ? 100 : 190 )

and `setDimension()` turns that into `w->setFixedWidth( desiredWidth )`. **The width is not
reachable from branding, from the QML, or from any config key**: it is a literal in the window's
constructor.

190 is only the ceiling, and it is not what this medium gets. `defaultFontHeight()` is
`QFontMetrics( f ).height()` for the default font at the default point size (`Gui.cpp:160`), which
here is **14** — so the middle term is 168 and the rail is **168px**, measured off plan/30's last
screenshot: the panel runs x=128..294 with its 1px seam at 295.

What that leaves for a label: 168 less the panel's two 16px margins, the row's two 10px margins,
the 16px step mark and the 11px gap after it is **87px**. Against the ninety labels this installer
can show — ten steps in nine languages — **eight do not fit**, measured from the shipped IBM Plex
TTF at 14px, taking the semibold width because the step you are on is semibold:

| label | language | width |
|---|---|---|
| Добро Пожаловать | ru | 130 |
| Zusammenfassung | de | 123 |
| Местоположение | ru | 117 |
| アプリケーション | ja | 112 (8 full-width glyphs at 14px) |
| Учётные записи | ru | 109 |
| Primeros pasos | es | 100 |
| Anwendungen | de | 93 |
| Приложения | ru | 87 |

So the report is exactly right, and it is not a rounding: ru Welcome needs 43px more than it has.

**The width is set from our own module rather than by patching Calamares.** There is precedent
in the file that gets the change: `LanguageViewStep.cpp`'s `retranslateWindowPanels()` already
walks `QApplication::topLevelWidgets()` for the two window panels — by the filename the window
loaded them from — because nothing in Calamares retranslates them. The same walk can call
`setFixedWidth()`. The alternative was `/etc/portage/patches/app-admin/calamares/`, which would
be one number in a diff and three consequences: calamares would have to be rebuilt from source on
every run to stop a cached binpkg answering in its place (portage decides a binpkg is good from
the ebuild, the CPV and the USE flags, and a user patch is none of those), the patch would have to
be refreshed on every calamares bump, and a failed `eapply` would kill an image build over a
sidebar's width. The failure mode of the call is the status quo: if a future Calamares stops
building that panel from that file, the panel is not found, a warning is logged, and the sidebar
is back to the width Calamares gives it, with elided labels.

`CalamaresApplication::initView()` constructs the window and *then* schedules `loadModules`, so by
the time this module's view step is constructed the sidebar widget exists. The call is made there,
with one `QTimer::singleShot(0, …)` retry and a `cWarning` if the panel is still not found — the
one thing this must not do is fail silently, because a sidebar that is too narrow looks like a
sidebar somebody chose.

**224px**, which leaves 145px for the label — 15px past the widest of the ninety, for the
difference between FreeType's advance widths and Qt's, and for the next translation. It is above
the 190 ceiling as well as above the 168, which is the point: a number that only cleared today's
font would go back to eliding on a medium whose default font is a point smaller.

The page pays the 56px. 1024 − 224 = 800 for the page, less the 44px margins, is 712 of content
against `Theme.qml`'s `contentMaxWidth` of 800, so nothing is capped and every page simply gets
narrower. What that does to the pages plan/30 took the scrollbars off — a narrower column wraps
taller — is a question for the medium and not for the checkout, and it is the one thing in this
plan that could come back with a second round of work.

## §3 The chooser's selection lived in two places and only one of them knew

`AccountsConfig::setConfigurationMap()` has set `m_mode = Local` since plan/26 §2, with a comment
saying the page "turns the first screen from a question into a confirmation". It does that for
`isNextEnabled()` and for the form the Next button opens — but not for the cards, because the QML
deliberately keeps the *UI's* source of truth in a `QQC2.ButtonGroup` and mirrors it into C++
through `onToggled`. A button group starts with nothing checked, and no card ever read the mode it
was already in. So the page has been opening on a chosen mode that the screen did not show, which
is worse than either answer on its own: Next is enabled and nothing says why.

`Component.onCompleted: if (modelData.mode === accounts.mode) checked = true` — an imperative
assignment at creation, not a binding, for the reason written above the group: a binding on
`checked` is broken by the first click anyway.

## §4 One exclamation, on the line that means it

Since plan/30 the Welcome panel lists only what is wrong, so every row's status chip is the same
exclamation in one of two tones, and the badge at the other end of the row already says which
(`Required` / `Optional`) in the same tone. The chip is therefore saying nothing the row does not
say twice — and it is the same 22px chip the verdict wears, which is the line that actually
decides whether this machine can be installed.

The rows lose their chip. The verdict keeps it. The comment above the verdict's chip, which reads
"the verdict wears the same mark its evidence does", becomes wrong by this change and is rewritten
rather than left to mislead: it is now the only mark on the page.

## What the medium said

Four passes on `out/immos-0.3.0-installer.img`, built from a wiped `immos-work` (682 packages, no
compiler diagnostics): a probe pass for coordinates, a language pass, a full walk to the summary,
and one `-nic none` boot for the Welcome panel.

**The rail is 224px**, read off the picture rather than believed: the seam detector reports
`(128, 351, 224)`. `Добро Пожаловать`, `Местоположение`, `Учётные записи`, `Zusammenfassung`,
`Anwendungen`, `アプリケーション` and `インストール` all stand whole, and so do the two meta
buttons — Japanese `このプログラムについて` is 155px of the 192 the rail now gives them, which at
168 it did not have.

**The set-time dialog lines up to the pixel.** Date, Time and AM/PM all top their boxes at y=403
and their labels share rows 380–389; the AM/PM select reads PM at 6:37 PM with `06:37` in the
field beside it. (The walk's click at the box's bottom border missed the popup, so the select's
own popup is unverified in this round — plan/30 §3 verified it, and nothing in §1 touches it.)

**The accounts chooser opens on Local**, accent border, accent wash and a filled radio, with Next
already lit — which is what the C++ had been saying on its own since plan/26.

**The Welcome panel's warning row carries no chip**: `internet — Network — not connected, not
required`, the amber `Optional` badge at the other end, and the page's only mark is the verdict's
tick beside "This computer can install Immutable OS 0.3.0."

### And one thing the 56px cost

**The disk list came back behind a scrollbar.** The page's lede is one line at 168px of rail and
two at 224, the list is what gave up the 36px, and two disks stopped fitting in it — the exact
shape plan/30 was asked to remove, reintroduced by this plan's own fix.

The list had `Layout.fillHeight: true` and nothing else, so it was always as tall as the page's
spare height and its scrollbar appeared the moment the content grew past that. It is now capped
at `list.contentHeight`: as tall as its rows on a machine with two disks, scrolling on one with
twelve, which is the only shape a scroller belongs in. The cap was measured offscreen with
`qmllint`'s sibling `qml` before it was written — two rows give a 138px view, twenty give a view
capped at the page's 536 with 1434 of content — because a ListView that is handed zero height
creates no delegates and can sit at zero forever, and a binding from a view's height to its own
content is exactly the shape that does it. Here the direction is safe: `contentHeight` follows
the delegates, which follow the view's WIDTH.

**And the cap on its own did not fix it**, which the second walk said and the first fix assumed
away. A cap cannot create room. Measured off the scrollbar itself — handle over track, with
Breeze's end buttons discounted — the list wants **141px** and the page could spare **124**, so
it still scrolled, by seventeen pixels, with the second row half-drawn. Worse, the `Item {
Layout.fillHeight: true }` added underneath to catch the surplus was a second claimant on it: a
ColumnLayout splits what is going spare between everything that can grow, so the list gave up
about fourteen pixels to a blank Item and kept its scrollbar with the spare space sitting at the
bottom of the page where nothing needed it. On the medium: the list ran 283..400 with the filler
and 283..405 without.

So the room is found rather than redistributed, and on this page only:

* the filler is gone — nothing else on the page competes for height;
* the gutter between the page's five blocks goes from 20 to 12, which is 32px across four gaps;
* the planned-layout panel gives up 8px of its own padding, 18 to 14.

That is 154px of viewport for 141px of rows, with 13 to spare. **The row padding is deliberately
not touched**: plan/30 set it at 10 and `tests/test-installer.sh` §6u pins it there, because a
row carries a 22px badge and a radio mark that 8px of padding would start crowding.

The case I expected this *not* to clear was a three-line lede, and the medium says there isn't
one: German's "Immutable OS wird darauf installiert, und alles, was jetzt darauf ist, wird
gelöscht." wraps to two lines like the English, and its disk page has no scrollbar either. The
page that would still scroll is one with three or more disks — which is the cap doing its job
rather than a seventeen-pixel overflow pretending to be one.

Every other page was checked for the same regression and none of them moved: the summary's six
rows are still one line each with no scroller, the accounts chooser's three subtitles still fit
on one line, the keyboard preview is unchanged, and the applications page scrolls as a whole page
under "Choose individually" exactly as plan/30 left it.

### The third build

`e12`: the disk page carries both rows, the planned layout, the warning and the encryption row
with no scroller, in English and in German. The AM/PM select's popup opens inside the modal with
PM current, the fields still level under it, and the clock reads 9:45 PM with `09:45` in the
field. The rail measures 224 on this build as it did on the last.
