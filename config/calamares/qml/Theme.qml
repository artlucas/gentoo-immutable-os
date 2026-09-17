/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The Immos Design System, resolved into QML (plan/28).
 *
 * ONE FILE IN THE REPOSITORY, NINE COPIES IN THE BUILD. This is the canonical copy;
 * scripts/stages/20-builder-setup.sh fans it out into every Calamares module's rendered
 * files/qml/ directory right after the overlay is rendered, and each module's CMakeLists.txt
 * lists qml/Theme.qml in its own qt6_add_resources call. So the tokens travel inside each .so
 * exactly like the page that uses them, and there is no second QML install path and no second
 * search order — the property every sibling CMakeLists has a paragraph about. A resource cannot
 * be half-installed; a shared QML module under /usr/lib64/qt6/qml can.
 *
 * NOT A SINGLETON, and that is the whole reason this is a plain QtObject. A QML singleton needs
 * a qmldir beside it AND an import path registered on the engine, which is the second search
 * order again, arriving by a different door. Instead every page OWNS one:
 *
 *     readonly property Theme ds: Theme {}
 *
 * on the page's root item, once. Nested delegates reach `ds` through the component scope chain —
 * the same mechanism Accounts.qml already relies on to reach `modeGroup` from inside a Repeater —
 * and children that take a `ds` of their own (Field, Button, the three account forms) are handed
 * `root.ds`, QUALIFIED. A bare `ds: ds` would resolve its right-hand side in the child's own
 * scope, where the child's `ds` property shadows the page's, and bind the property to itself:
 * a binding loop, an undefined theme, and a page painted in whatever null evaluates to.
 * Instantiation is free — this object holds constants and allocates nothing.
 *
 * LIGHT THEME, TEAL ACCENT, AND ONLY THAT. The design system ships a light `:root` palette and a
 * [data-ds="dark"] override, plus ten swappable accents. The installer is not ds-switchable
 * — it runs for ten minutes on a live medium, from one branding component, and a page that could
 * be either ds is a page whose contrast nobody has checked. The values below are the light
 * palette with the teal accent, read out of the design system's tokens/*.css and resolved through
 * colors.css' primitives. They are recorded a second time in config/branding/README.md, and
 * tests/test-installer.sh requires every literal here to appear there — the same discipline
 * tests/test-splash-assets.sh applies to the splash colours, for the same reason: a colour with
 * no provenance is a colour the next person has to guess about.
 *
 * WHAT DOES NOT BELONG HERE: anything that is not in the design system. This file is a
 * transcription, not a place to invent a shade that looked better on one page.
 */
import QtQuick

QtObject {
    id: tokens

    // ======== colour primitives (tokens/colors.css) ================================
    //
    // Only the ones the semantic aliases below actually resolve to, plus the two the disk page's
    // partition bar needs by name. The full Basalt ramp is not transcribed: an unused token is a
    // value nobody has checked against anything.
    readonly property color basalt50:  "#f6f7f9"
    readonly property color basalt100: "#eceef2"
    readonly property color basalt200: "#d8dde4"
    readonly property color basalt300: "#b9c0cc"
    readonly property color basalt400: "#8b94a3"
    readonly property color basalt500: "#66707f"
    readonly property color basalt700: "#363e4a"
    readonly property color basalt900: "#161b21"
    readonly property color white:     "#ffffff"

    // ======== accent (tokens/ds-palettes.css, [data-accent="teal"]) =============
    readonly property color accentTint:   "#c3ede6"
    readonly property color accentSoft:   "#5accbb"
    readonly property color accent:       "#0e9c8a"
    readonly property color accentHover:  "#0a7e70"
    readonly property color accentStrong: "#0a645a"
    readonly property color accentOn:     "#ffffff"

    // ======== semantic aliases (tokens/semantic.css, :root) ========================
    //
    // THE LIGHT-THEME NESTING IS THE INVERSE OF THE DARK ONE, and every panel in the mockup
    // depends on it: surfaceCard is WHITE and surfacePage is the GREY, so an inset panel — the
    // planned disk layout, the keyboard preview, the applications total, the domain-join box —
    // is grey on white. Under dark it would have been the other way round. Reading these two as
    // "page = outer, card = inner" is the mistake that makes every panel disappear.
    readonly property color surfacePage:    basalt50
    readonly property color surfaceCard:    white
    readonly property color surfaceSunken:  basalt100
    readonly property color surfaceRaised:  white
    readonly property color surfaceInverse: basalt900
    readonly property color surfaceOverlay: Qt.rgba(13 / 255, 17 / 255, 22 / 255, 0.45)

    readonly property color textStrong: basalt900
    readonly property color textBody:   basalt700
    readonly property color textMuted:  basalt500
    readonly property color textSubtle: basalt400
    readonly property color textOnAccent: accentOn
    readonly property color textInverse:  basalt50
    readonly property color textLink:     accentHover

    readonly property color borderSubtle:  basalt200
    readonly property color borderDefault: basalt300
    readonly property color borderStrong:  basalt400
    readonly property color divider:       basalt200

    readonly property color statusSuccess:   "#158048"
    readonly property color statusSuccessBg: "#d9f2e3"
    readonly property color statusWarning:   "#b47f0e"
    readonly property color statusWarningBg: "#fbeecb"
    readonly property color statusDanger:    "#bd2c2c"
    readonly property color statusDangerBg:  "#fbdedd"
    readonly property color statusInfo:      "#2159c1"
    readonly property color statusInfoBg:    "#dbe7fb"

    // The selected-row fill, which the mockup writes as
    //     color-mix(in srgb, var(--accent) 14%, var(--surface-card))
    // and QML has no operator for. Precomputed rather than left as a mix() call at every use
    // site, because it appears on five pages and one rounding is better than five.
    readonly property color accentWash: mix(accent, surfaceCard, 0.14)

    // ======== geometry (tokens/radius.css, tokens/spacing.css) =====================
    //
    // Pixels, not Kirigami.Units: the design system states its grid in px and the window is a
    // fixed 1024x640 (branding.desc). Scaling these by the font metric — which is what
    // Kirigami.Units.gridUnit does — would make the 4px grid land wherever the user's font size
    // put it, and the mockup's alignments are the thing being reproduced.
    readonly property int radiusSm:   4
    readonly property int radiusMd:   8
    readonly property int radiusLg:   12
    readonly property int radiusXl:   16
    readonly property int radiusPill: 999

    readonly property int borderWidth:       1
    readonly property int borderWidthStrong: 2   // --border-width-strong is 1.5px; QML border
                                                 // widths are integers and 1 loses the emphasis

    readonly property int space1:  4
    readonly property int space2:  8
    readonly property int space3:  12
    readonly property int space4:  16
    readonly property int space5:  20
    readonly property int space6:  24
    readonly property int space8:  32
    readonly property int space10: 40
    readonly property int space12: 48

    // Control heights, from the design system's component CSS (.im-btn--md, .im-input, …). They
    // are not derivable from the spacing scale and every page needs them to agree.
    readonly property int controlHeightSm: 32
    readonly property int controlHeightMd: 40
    readonly property int controlHeightLg: 48

    // The content column. The mockup caps its pages at 720px (prose-led) or 760-800px (grid-led);
    // 800 is the widest, and pages narrower than that set their own.
    readonly property int contentMaxWidth: 800

    // ======== type (tokens/typography.css) =========================================
    //
    // ARCHIVO IS NOT PACKAGED IN GENTOO. The design system's display face is Archivo; the only
    // Archivo in this repository is the outlined wordmark in config/branding/wordmark.svg, which
    // exists precisely so the build needs no font binary. Shipping a font package for the
    // installer's headings was weighed and rejected, so fontDisplay is IBM Plex Sans and the
    // weight carries the emphasis instead. This is a SUBSTITUTION, recorded here and in
    // config/branding/README.md, not a reading of the token file.
    //
    // media-fonts/ibm-plex is on the installer medium and nowhere else — see
    // config/portage/sets/installer. The fallbacks are what the medium has if that ever changes.
    readonly property string fontDisplay: "IBM Plex Sans"
    readonly property string fontSans:    "IBM Plex Sans"
    readonly property string fontMono:    "IBM Plex Mono"

    readonly property int textXs:   12
    readonly property int textSm:   14
    readonly property int textBase: 16
    readonly property int textMd:   18
    readonly property int textLg:   22
    readonly property int textXl:   28
    readonly property int text2xl:  36

    // The page H1: 34px in the mockup, which is between --text-xl and --text-2xl because the
    // design sets it as a literal. Transcribed as the literal it is.
    readonly property int textHeading: 34

    readonly property int weightRegular:  Font.Normal     // 400
    readonly property int weightMedium:   Font.Medium     // 500
    readonly property int weightSemibold: Font.DemiBold   // 600
    readonly property int weightBold:     Font.Bold       // 700

    readonly property real trackingTight: -0.02   // em, for display sizes
    readonly property real trackingCaps:   0.08   // em, for the uppercase mono eyebrow labels

    readonly property real leadingSnug:    1.25
    readonly property real leadingNormal:  1.5
    readonly property real leadingRelaxed: 1.65

    // ======== motion (readme.md, "Animation") ======================================
    //
    // "quick and unfussy — 120-180ms ease transitions for hover/state". No bounces, and the only
    // looped animation in the system is a spinner this installer does not draw.
    readonly property int durationFast: 120
    readonly property int durationBase: 150
    readonly property int durationSlow: 180

    // ======== helpers ==============================================================

    /* Linear sRGB mix, the operation CSS spells color-mix(in srgb, a f%, b). `f` is a's share.
       Used for accentWash above and available to pages that need a one-off tint; prefer a token. */
    function mix(a, b, f) {
        return Qt.rgba(a.r * f + b.r * (1 - f),
                       a.g * f + b.g * (1 - f),
                       a.b * f + b.b * (1 - f),
                       a.a * f + b.a * (1 - f));
    }

    /* Qt gives letterSpacing in PIXELS and the design system states tracking in EM, so every use
       has to multiply by the size it is applied at. Doing that by hand at each call site is how
       one heading ends up with the tracking of another. */
    function tracking(em, pixelSize) {
        return em * pixelSize;
    }
}
