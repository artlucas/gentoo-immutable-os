/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The Immos Design System's button (plan/28).
 *
 * SHARED, AND STAGED THE WAY Theme.qml AND Field.qml ARE — see the header of Theme.qml for why
 * config/calamares/qml/ is copied into each module's resource at build time rather than installed
 * once and imported by URI.
 *
 * NOT a QQC2.Button with a custom background, which is the obvious thing and does not work: the
 * medium runs qqc2-desktop-style, whose Button draws Breeze's shape — its height, its radius, its
 * gradient and its focus ring — out of a Kirigami.Theme this page has already overridden for
 * colour. Overriding `background` leaves the style's `contentItem` metrics and padding behind, so
 * the result is a brand-coloured Breeze button rather than the design system's. Every control on
 * these pages that the style would otherwise own is drawn instead, and this is the one that four
 * pages needed.
 *
 * WHAT IT DOES KEEP FROM QQC2: nothing, deliberately — it is an Item with a HoverHandler and a
 * TapHandler and an Accessible role. The one thing a real AbstractButton would add here is
 * keyboard activation, so that is written out below rather than lost.
 *
 * NO STRINGS. The label is passed in, because the builder's lupdate is built without QML support
 * and a qsTr() in this file would reach no catalogue (plan/27 §1).
 *
 * Variants and sizes are the design system's own: primary (accent fill), secondary (card fill,
 * a border), ghost (no fill until hover) and danger (the status colour); sm 32, md 40, lg 48.
 */
import QtQuick

Item {
    id: button

    property Theme ds
    property string label
    /*! "primary" | "secondary" | "ghost" | "danger" */
    property string variant: "primary"
    /*! "sm" | "md" | "lg" */
    property string size: "md"
    /*! The glyph drawn before the label, or "" for none. "refresh" is the only one, and that is
     *  the whole vocabulary on purpose — see the Canvas below for why this is a name rather than
     *  a source URL or an icon-theme string. */
    property string icon: ""
    // NO `enabled` OF ITS OWN. Item already has one, a redeclaration shadows it, and a shadowed
    // `enabled` is the worst of both: the handlers below read this file's copy while everything
    // outside — focus, the accessibility tree, a parent disabling a whole panel — reads Item's.
    // The linter says so — a `// qmllint ...` line is itself a directive, so it cannot be
    // quoted here — which is why this comment exists instead of the property.

    signal clicked()

    readonly property int _height: button.size === "sm"
        ? button.ds.controlHeightSm
        : (button.size === "lg" ? button.ds.controlHeightLg : button.ds.controlHeightMd)
    readonly property int _padding: button.size === "sm"
        ? button.ds.space3
        : (button.size === "lg" ? button.ds.space6 : button.ds.space4)
    readonly property int _fontSize: button.size === "sm"
        ? button.ds.textSm
        : (button.size === "lg" ? button.ds.textMd : button.ds.textBase)

    readonly property color _fill: button.variant === "primary"
        ? (hover.hovered ? button.ds.accentHover : button.ds.accent)
        : (button.variant === "danger"
            ? button.ds.statusDanger
            : (button.variant === "secondary"
                ? (hover.hovered ? button.ds.surfaceSunken : button.ds.surfaceCard)
                : (hover.hovered ? button.ds.surfaceSunken : "transparent")))
    readonly property color _ink: button.variant === "primary" || button.variant === "danger"
        ? button.ds.accentOn
        : (button.variant === "secondary" ? button.ds.textStrong : button.ds.textBody)

    implicitWidth: content.implicitWidth + 2 * button._padding
    implicitHeight: button._height
    // The design system's disabled state: half opacity and a cursor that says so.
    opacity: button.enabled ? 1 : 0.5

    activeFocusOnTab: button.enabled

    Accessible.role: Accessible.Button
    Accessible.name: button.label
    Accessible.onPressAction: if (button.enabled) { button.clicked(); }

    Keys.onSpacePressed: if (button.enabled) { button.clicked(); }
    Keys.onReturnPressed: if (button.enabled) { button.clicked(); }
    Keys.onEnterPressed: if (button.enabled) { button.clicked(); }

    HoverHandler {
        id: hover
        enabled: button.enabled
        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        enabled: button.enabled
        onTapped: button.clicked()
    }

    Rectangle {
        id: body

        anchors.fill: parent
        radius: button.ds.radiusMd
        color: button._fill
        // Only the secondary variant is bordered; the others carry their own fill, and the
        // design's rule is one or the other rather than both.
        border.width: button.variant === "secondary" ? button.ds.borderWidth : 0
        border.color: button.ds.borderDefault
        // "press = 1px nudge down", the design system's own words.
        y: tap.pressed ? 1 : 0

        Behavior on color {
            ColorAnimation { duration: button.ds.durationBase }
        }

        TapHandler { id: tap; enabled: button.enabled }

        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            visible: button.activeFocus
            radius: button.ds.radiusMd + 3
            color: "transparent"
            border.width: 3
            border.color: button.ds.mix(button.ds.accent, button.ds.surfaceCard, 0.4)
        }

        Row {
            id: content

            anchors.centerIn: parent
            spacing: button.ds.space2

            // DRAWN, LIKE EVERY OTHER MARK IN THIS INSTALLER, and for the reason Done.qml's tick
            // gives at length: Kirigami.Icon "view-refresh" resolves out of the Breeze icon theme,
            // in Breeze's colour and Breeze's weight, which is the one thing a control in this
            // design system may not be. A font glyph is the other obvious answer and is worse —
            // U+21BB is not in IBM Plex Sans, so fontconfig would substitute some other family
            // for that one character and the button would carry a stranger's arrow.
            //
            // The reload mark: an open ring with the gap at the right, and a filled head at the
            // upper end pointing down into it. Laid out on a 24-unit grid and scaled, so the
            // proportions hold at every button size.
            Canvas {
                id: iconCanvas

                anchors.verticalCenter: parent.verticalCenter
                visible: button.icon === "refresh"
                // 1.3x the label, not the 1.15 this started at: the arrowhead is ~2px across at
                // 16px and rasterises to a faint spike, and the mark stops reading as an arrow.
                // Rendered offscreen at 16/18/24/48/120 to pick the smallest size that still
                // reads — see the commit.
                width: visible ? Math.round(button._fontSize * 1.3) : 0
                height: width

                // The ink never changes on hover — every variant's foreground is constant across
                // its states — but a variant CAN change under a binding, and a Canvas repaints
                // only when it is told to. Cheaper than the class of bug where the glyph keeps
                // the colour it was first painted in.
                readonly property color ink: button._ink

                onInkChanged: requestPaint()
                onWidthChanged: requestPaint()

                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    if (width <= 0) {
                        return;
                    }

                    const u = width / 24;
                    const cx = 12 * u;
                    const cy = 12 * u;
                    const r = 6.4 * u;
                    // 0 is east and the angle runs clockwise on screen, so this sweeps 248
                    // degrees and leaves the rest as the gap, on the right. The ring is smaller
                    // than the box because the head has to fit inside it.
                    const a0 = 0.34 * Math.PI;
                    const a1 = 1.72 * Math.PI;

                    ctx.strokeStyle = iconCanvas.ink;
                    ctx.lineWidth = 2 * u;
                    ctx.lineCap = "round";
                    ctx.beginPath();
                    ctx.arc(cx, cy, r, a0, a1, false);
                    ctx.stroke();

                    // The head, at the far end of the stroke. `t` is the clockwise tangent there
                    // and `n` its normal, so the triangle is built from the arc's own direction
                    // rather than from angles measured a second time by hand.
                    const px = cx + r * Math.cos(a1);
                    const py = cy + r * Math.sin(a1);
                    const tx = -Math.sin(a1);
                    const ty = Math.cos(a1);
                    const nx = -ty;
                    const ny = tx;

                    // Pulled back along the tangent so the triangle's base sits ON the stroke's
                    // end rather than past it: a head that starts where the line stops reads as
                    // a line with a lump on it.
                    const bx = px - tx * 1.3 * u;
                    const by = py - ty * 1.3 * u;

                    ctx.fillStyle = iconCanvas.ink;
                    ctx.beginPath();
                    ctx.moveTo(bx + tx * 4.8 * u, by + ty * 4.8 * u);
                    ctx.lineTo(bx + nx * 3.4 * u, by + ny * 3.4 * u);
                    ctx.lineTo(bx - nx * 3.4 * u, by - ny * 3.4 * u);
                    ctx.closePath();
                    ctx.fill();
                }
            }

            Text {
                id: text

                anchors.verticalCenter: parent.verticalCenter
                text: button.label
                color: button._ink
                font.family: button.ds.fontSans
                font.pixelSize: button._fontSize
                font.weight: button.ds.weightSemibold
            }
        }
    }
}
