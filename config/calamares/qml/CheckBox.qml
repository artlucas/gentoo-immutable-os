/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The Immos Design System's check box (plan/30 §1).
 *
 * SHARED, AND STAGED THE WAY Theme.qml, Button.qml AND Field.qml ARE — see the header of
 * Theme.qml for why config/calamares/qml/ is copied into each module's Qt resource at build time
 * rather than installed once and imported by URI.
 *
 * WHY IT EXISTS. Two pages had already drawn this control by hand — LocalForm.qml's "log in
 * automatically" and Done.qml's "restart now" — because qqc2-desktop-style paints Breeze's box,
 * its size, its radius, its tick and its focus ring, whatever Kirigami.Theme says about colour.
 * Both drawings were correct and both were the same drawing, and both had the same hole in them:
 * a RowLayout with a TapHandler is a control the keyboard cannot reach or operate. Fixing that
 * twice would have been the moment a third page copied the second copy.
 *
 * NOT a QQC2.CheckBox with `indicator: null`, which is the OTHER shape in this installer and is
 * the right one where the control is inside a layout that the style is already managing —
 * Apps.qml's application tiles and Location.qml's network-time box are whole cards whose
 * background, indicator and contentItem are all replaced, so what is left of QQC2 there is worth
 * having. Here there is no card: it is a mark and a sentence, and an AbstractButton wrapped round
 * them would contribute a `padding`, a `spacing` and an `implicitWidth` that the two call sites
 * would then have to neutralise. The one thing a real AbstractButton would add is keyboard
 * activation, so that is written out below rather than lost.
 *
 * NO STRINGS. The label is passed in, because the builder's lupdate is built without QML support
 * and a qsTr() in this file would reach no catalogue (plan/27 §1).
 *
 * `checked` IS NOT A BINDING AT EITHER CALL SITE, and must not become one here: C++ is the source
 * of truth on both pages, the control writes into it on `toggled`, and a Connections on the
 * config object puts back whatever C++ accepted. This component therefore does NOT toggle itself
 * — it emits, and waits to be told. A control that flipped its own state and then had it
 * corrected a frame later is how a check box comes to disagree with the install it describes.
 */
import QtQuick
import QtQuick.Layouts

RowLayout {
    id: control

    property Theme ds
    property string label
    property bool checked: false

    /*! Emitted when the user activates the control — by click, by Space or by Return. Carries
     *  the value the user asked for, NOT the value this control now holds: see the header. */
    signal toggled(bool value)

    spacing: control.ds.space2
    // The design system's disabled state, and the half Qt does not do for a hand-drawn control.
    opacity: control.enabled ? 1 : 0.5

    // THE WHOLE ROW IS ONE TAB STOP, one hit target and one accessible object (plan/27 §7): the
    // words beside a mark are words somebody clicks, and they are also the words a screen reader
    // announces. A disabled item is skipped by the tab walk on its own, so this is unconditional.
    activeFocusOnTab: true

    Accessible.role: Accessible.CheckBox
    Accessible.name: control.label
    Accessible.checked: control.checked
    Accessible.onToggleAction: if (control.enabled) { control.toggled(!control.checked); }

    Keys.onSpacePressed: if (control.enabled) { control.toggled(!control.checked); }
    Keys.onReturnPressed: if (control.enabled) { control.toggled(!control.checked); }
    Keys.onEnterPressed: if (control.enabled) { control.toggled(!control.checked); }

    HoverHandler {
        id: hover
        enabled: control.enabled
        cursorShape: Qt.PointingHandCursor
    }

    TapHandler {
        enabled: control.enabled
        onTapped: control.toggled(!control.checked)
    }

    // The design system's Checkbox mark: a 20px square with a 2px ring, filled with the accent
    // and ticked when on.
    Rectangle {
        id: box

        Layout.alignment: Qt.AlignVCenter
        implicitWidth: 20
        implicitHeight: 20
        radius: control.ds.radiusSm
        color: control.checked ? control.ds.accent : control.ds.surfaceCard
        border.width: control.ds.borderWidthStrong
        border.color: control.checked || hover.hovered
            ? control.ds.accent
            : control.ds.borderStrong

        Behavior on color {
            ColorAnimation { duration: control.ds.durationBase }
        }

        // The 3px ring, drawn OUTSIDE the box so it does not eat the mark — Button.qml's and
        // Field.qml's ring, at the same offset and in the same colour, because a keyboard user
        // crossing this installer should be learning one shape and not five.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            visible: control.activeFocus
            radius: control.ds.radiusSm + 3
            color: "transparent"
            border.width: 3
            border.color: control.ds.mix(control.ds.accent, control.ds.surfaceCard, 0.4)
        }

        Text {
            anchors.centerIn: parent
            visible: control.checked
            text: "✓"
            color: control.ds.accentOn
            font.family: control.ds.fontSans
            font.pixelSize: control.ds.textXs
            font.weight: control.ds.weightBold
        }
    }

    Text {
        Layout.fillWidth: true
        text: control.label
        color: control.ds.textBody
        wrapMode: Text.WordWrap
        font.family: control.ds.fontSans
        font.pixelSize: control.ds.textBase
    }
}
