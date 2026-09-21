# plan/32 — the page that ran off the bottom, the icon that was ours, and a logo nobody could read

Three reports off the build of plan/31. Two of them are the same kind of finding as plan/31's: the
checkout looks right and the screen disagrees. The third is a decision that was made once, for the
sidebar, and then quietly applied to a second thing it was never right for.

    1. On the Finish page, ticking "Restart now" puts its reminder line below the bottom of the
       page. Drop the lede's second sentence and raise the table.
    2. Calamares' window wears our logo. It should wear Calamares' own icon.
    3. The sidebar logo is too small to read. Make it a horizontal lockup — mark left, wordmark
       right — instead of the vertical stack.

## §1 The Finish page is 586px tall in a 576px viewport

`Done.qml` centres one `ColumnLayout` in the page with `anchors.centerIn: parent`. That is not a
layout that can fail loudly: a column taller than its parent is centred anyway, and the overflow
is split between the top and the bottom. Half of it goes under the navigation bar and half of it
goes off the top, and nothing is logged.

**The viewport is 576px and it is not negotiable.** The window is `1024px,640px`
(`branding.desc.in`). `CalamaresWindow` builds the navigation panel through `setDimension()`,
which for a horizontal panel does `qBound(16, rootObject()->height(), 64)` —
`calamares-navigation.qml` asks for 72, so the bar is **64**. `ViewManager::insertViewStep()`
sets contents margins on `step->widget()->layout()`, and `DoneViewStep::widget()` returns a bare
`QQuickWidget` with no layout at all, so there are none. 640 − 64 = **576**, and with plan/31's
224px rail the width is 800, which the column caps at 600.

What the column asks for, with the box ticked (IBM Plex at the design system's sizes,
`Text.height ≈ pixelSize × 1.32`, the lede at `leadingNormal` 1.5):

| item | height |
|---|---|
| the success mark | 72 |
| gap (`space6 + space1`) | 28 |
| title (34px, one line) + 10 + lede (18px × 1.5, **two** lines) | 126 |
| gap | 28 |
| the table, at its cap | 260 |
| gap | 28 |
| checkbox 20 + 8 + reminder (12px, one line) 16 | 44 |
| **total** | **586** |

586 against 576. Unticked the column is 562 and everything fits, which is why this is a bug that
only appears when the box is ticked — the report is exactly right about the trigger and exactly
right about where the line goes.

### Why "raise the table" is not "top-align it" on its own

Centring is the arrangement that *minimises* the visible overflow: at height *H* the bottom edge
is at `(576 + H)/2`, so it hangs over by `(H − 576)/2` — 5px here, with another 5px lost off the
top of the success mark. Top-anchoring at the page margin *m* puts the bottom at `m + H`, which
overhangs by `H + m − 576` — 38px. **Top-aligning a column that does not fit makes the clipping
worse, not better**, and the two are equal only at `H = 576 − 2m`. So the page has to be made to
fit first, and then raised; either half on its own is not a fix.

It is made to fit twice over:

- **The lede loses its second sentence**, which is what the report asks for and is also the one
  line on this page that was not carrying its weight. "Anything still downloading finishes after
  that" is about `appsetup`, which has already run by the time this page is drawn, and on an
  offline install it never ran at all. It costs a wrapped line at 18px/1.5 — **36px**.
- **The column's gaps go from `space6 + space1` (28) to `space6` (24)**, three of them — **12px**.
  This page is the only one in the installer that uses the +4; every other page's sections are
  `space6` apart (`Review.qml`, `Apps.qml`, `Accounts.qml`).

538 + a 28px top margin is **566**, with 10px of slack, and the table has moved up by 48px from
where centring had it. The 260px cap stays: six rows at 42.5 (a 14px label against a 12px mono
value, plus `2 × space3`) is 255, so the cap is doing nothing today and is there for a language
whose values wrap.

`anchors.centerIn` becomes `anchors.top` + `anchors.horizontalCenter` with
`anchors.topMargin: ds.pageMarginV` — the same 28 every other page's sheet uses. The page stays
horizontally centred, which is the half of the centring argument that was about the content
("nothing to scan, only something to be told") rather than about the window.

### The string is in nine places, not one

`DoneConfig::pageLede()` is a `tr()`, so the sentence lives in the eight branding `.ts`
catalogues as well as in the C++. `scripts/lib/check-translations.py` check 4 requires every
`<source>` to appear **verbatim** in the module sources, and stage 40 runs the same checker before
`lrelease` — so a trimmed English string with eight stale catalogues is a build failure, not a
silent English line. All eight translations lose their second sentence with the source.

## §2 The window icon was never ours to set

`CalamaresApplication::initBranding()` ends with

    setWindowIcon( QIcon( Branding::instance()->imagePath( Branding::ProductIcon ) ) );

and that is the **only** reader of `productIcon` in Calamares. `branding.desc.in` points it at
`logo.png` — so the window, the task switcher and the title bar wear a 144×212 brand block scaled
into a square icon box, which is the shape an icon is least able to be.

The stock icon is on the medium already: `src/calamares/CMakeLists.txt` installs
`data/images/squid.svg` as `/usr/share/icons/hicolor/scalable/apps/calamares.svg`, which is also
what `calamares.desktop`'s `Icon=calamares` and our own autostart copy resolve to. So the panel
pin and the menu entry have been showing the stock icon all along and only the window disagreed.

**It has to be named by absolute path, not as an icon name.** `Branding`'s image loader accepts
either — it falls back to `QIcon::fromTheme()` and keeps the bare name when the file is not in the
component directory — but the *consumer* above is `QIcon( QString )`, the **file** constructor.
`productIcon: "calamares"` would therefore pass the branding's own validation and produce a null
icon, which is the failure mode this repo keeps finding in Qt: no warning, no log line, just a
window with the generic icon. `QDir::absoluteFilePath()` returns an absolute argument unchanged,
so the path survives the loader intact.

Two consequences for the checks:

- Stage 40 asserts the file is in the target, beside the other branding assertions. Calamares
  reports a missing branding image as `Image file … does not exist` **at startup, on the medium** —
  it is an installer that does not start, which is the class of failure section 5b of
  `tests/test-installer.sh` exists for.
- That same section walks every image name in `branding.desc` and requires it to be either
  committed in the branding directory or generated by stage 40. An absolute path is a third case:
  a file that comes from the image itself. It passes when stage 40 names it — which is the same
  evidence, one indirection over.

`productLogo` and `productWelcome` stay `logo.png`. The sidebar is the one place a brand block
belongs, and `productWelcome` has no reader at all here (`tests/test-installer.sh` asserts the
greeting page does not draw a second logo).

## §3 The sidebar logo renders 22 pixels wide

Not "small": **22 × 32**, and the arithmetic is closed. `build_block()` composes a column — a 132px
mark box over a 34px gap over the 143.43 × 46 wordmark — which at `--logo-scale 1` is a
**144 × 212** PNG. `calamares-sidebar.qml` draws it with `Layout.preferredHeight: 32` and
`PreserveAspectFit`, so the width is `32 × 144 / 212 = 21.7`. Inside that the wordmark gets
**21.7 × 7** and the logomark's ink gets **12 × 16**. At seven pixels of cap height "immos" is not
a word, it is a texture.

And the rail has the room. Since plan/31 it is 224px wide; less the panel's two `space4` margins
and the logo's own `space2` left margin, **184px** is available and 22 of it was being used.

### The lockup

Same three slabs, same wordmark, same re-shading, same ground, one function further down
(`load_marks()`) — rearranged: the mark, then `GAP`, then the wordmark, each vertically centred
on the other.

**Composed from the mark's ink, not from `MARK_BOX`**, and that is the one number the two
arrangements do not share. The slab PNGs are square canvases with a small drawing inside them: at
the design baseline the ink measures **81.5 × 108** in a 130px image, so a quarter of the width
and a tenth of the height either side is transparent padding — and `MARK_BOX` is a 132px layout
box around *that*, sized for a splash with a wordmark below it and a screen above. A column
centred on a screen can afford both. A row drawn **to a height** in a 224px rail can afford
neither: every transparent row comes off the mark the user is meant to see, and every transparent
column widens the gap the lockup exists to set. Cropped to the ink, the baseline lockup is
81.5 + 34 + 143.43 = **260 × 108**, an aspect of 2.41:1 against the stack's 0.68:1.

Drawn at **48px** tall that is 116 × 48 in a 184px budget, and everything in it is **2.9×** what
it was: the wordmark goes from 21.7 × 7 to 64 × 20, the mark's ink from 12 × 16 to 36 × 48. The
sidebar's column grows by 16px, in a rail with ~140px of slack below the meta buttons.

`sourceSize.height` goes from 64 to 96 — still **a constant**, which is the whole of that item's
long comment: `sourceSize` feeds `implicitHeight`, `implicitHeight` is what a layout child is
sized from, and `sourceSize.height: height * 2` is the cycle that grew the window by a factor of
two per layout pass until an 11.7 GB backing store failed to allocate. The QML engine does not
call that a binding loop, because the cycle runs through `QQuickLayout`'s C++.

### What this costs, and where the line is drawn

It breaks "one layout function", and that is worth stating rather than glossing: the README, the
branding descriptor and three comments in the generator all argue that the sidebar must be the
same block of pixels as the boot splash, because the user sees the two about a minute apart.

The argument survives the change with its scope corrected. What the splash and the installer
share is **the drawing** — the same slabs, the same shading LUT, the same wordmark, the same
generator — and what they have not shared since plan/28 is the **ground**. `--bg` and `--ink`
already apply to `--logo` and `--slide` and to nothing else, precisely because those two artefacts
belong to the installer's light theme and everything before a desktop exists belongs to the dark
one. The lockup takes the same line: `--lockup` is a third argument that applies to the same two
artefacts, for the same reason. A boot splash is a full screen with a column in the middle of it;
a 224px rail is a strip with a lockup at the top; they are the same mark, composed for the space
each has.

So `build_block()` is untouched — the stub bitmap, the KMS sprite container's band-slicing (which
assumes a vertical stack of slabs and asserts it), the Plasma splash theme and its preview all
keep composing exactly what they compose today. `build_lockup()` is a second, much shorter
function beside it, and it loads and re-shades through the same helpers, so the slabs cannot drift.

Both installer artefacts take it — the sidebar logo and the progress-page slide — which is the
answer to "who else": `slide.png` is the other thing the installer draws the block on, and a
640×360 panel carrying a 309 × 132 lockup is a better composition than the same panel carrying a
144 × 212 column. The Plasma splash's `previews/splash.png`, which is `build_slide()`'s second
caller and passes no `--bg`, passes no `--lockup` either and stays the stack it has always been.

### The assertion that has to move with it

Two assertions move with the geometry, and one is added. `tests/test-splash-assets.sh` proves
that re-inking the wordmark changes the wordmark and not the slabs, by diffing two logos built
with different `--ink` and asserting
`diff[1] > a.height // 2` — *the difference is in the bottom half, below the mark box*. In a
lockup the wordmark is vertically centred and the correct claim is `diff[0] > a.width // 2`: the
difference is in the **right** half, beside the mark. Same property, same strength, rotated with
the geometry. The "same place on both grounds" pair is built `--lockup` on both sides, so it stays
a statement about the ground. And the new one is the one that would otherwise have no check at
all: that `--lockup` produces a row (wider than twice its height) where the default produces a
column (taller than wide) — a flag that silently did nothing would leave a 22px logo in the rail
and a build that passed. The tests that check the two grounds, the refusal of a malformed `--bg` and the
refusal of a wordmark inked its own ground colour are unchanged, as is the container-reassembly
test — that one calls `build_block()` directly and is about the KMS hand-off.

## §4 What is not in this plan

The accounts page's password fields were to get a Caps Lock warning, and that is dropped rather
than deferred with a design. The note worth keeping is the mechanism, because it is the reason the
question came up at all: **Qt has no Caps Lock state**. `Qt::KeyboardModifiers` does not carry it
and `QGuiApplication::queryKeyboardModifiers()` cannot return it, so a warning has to be inferred
from key events (a letter arriving in the case Shift did not ask for) or read out of
`/sys/class/leds/*::capslock/brightness`. Neither is a line of QML, and there is nothing in
`Field.qml` today that would have made it one.
