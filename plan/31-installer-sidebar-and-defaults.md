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

## §2 The sidebar is 190px because Calamares says so

`CalamaresWindow.cpp:503` builds the sidebar with

    qBound( 100, Calamares::defaultFontHeight() * 12, w < windowPreferredWidth ? 100 : 190 )

and `setDimension()` turns that into `w->setFixedWidth( desiredWidth )`. `windowPreferredWidth` is
1024 (`utils/Gui.h:97`) and branding.desc asks for a 1024px window, so the upper bound is 190 and
the font-derived middle term is above it on any normal font. **The width is not reachable from
branding, from the QML, or from any config key**: it is a literal in the window's constructor.

Measured against that: the panel's 16px margins, the row's 10px margins, the 16px step mark and
the 11px gap after it leave **111px** for the label. The widest label this installer can show is
`Добро Пожаловать` (ru, Welcome) at **130px** in IBM Plex Sans 14px — measured from the shipped
TTF, taking the semibold width since the current step is semibold. Four labels are over budget:

| label | language | width |
|---|---|---|
| Добро Пожаловать | ru | 130 |
| Zusammenfassung | de | 123 |
| Местоположение | ru | 117 |
| アプリケーション | ja | 112 (8 full-width glyphs at 14px) |

So the report is exactly right, and it is not a rounding: ru Welcome needs 19px more than it has.

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
is 190px with elided labels again.

`CalamaresApplication::initView()` constructs the window and *then* schedules `loadModules`, so by
the time this module's view step is constructed the sidebar widget exists. The call is made there,
with one `QTimer::singleShot(0, …)` retry and a `cWarning` if the panel is still not found — the
one thing this must not do is fail silently, because a sidebar that is too narrow looks like a
sidebar somebody chose.

**224px**, which leaves 145px for the label — 15px past the widest one, for the difference
between FreeType's advance widths and Qt's, and for the next translation. The page loses the same
30px: 1024 − 224 = 800 for the page, less the 44px margins, is 712 of content against `Theme.qml`'s
`contentMaxWidth` of 800, so no page changes shape. What that does to the pages plan/30 took the
scrollbars off — they wrap taller in a narrower column — is a question for the medium, not the
checkout.

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
