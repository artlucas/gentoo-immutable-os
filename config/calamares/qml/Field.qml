/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A labelled text field, in the Immos Design System's shape (plan/28).
 *
 * SHARED, AND STAGED THE WAY Theme.qml IS. This is the second file in config/calamares/qml/;
 * scripts/stages/20-builder-setup.sh copies it into the rendered files/qml/ of every module whose
 * CMakeLists names `qml/Field.qml`, so it travels inside that module's .so like the page that
 * uses it. Read the header of Theme.qml for why that is the arrangement rather than a QML module
 * under /usr/lib64/qt6/qml.
 *
 * WHY A COMPONENT AND NOT Kirigami.FormLayout, WHICH THIS REPLACES. The design system puts the
 * label ABOVE its field, at 14px/500 in the strong text colour, with a 12px hint or error under
 * it — and the fields sit in a two-column grid. Kirigami.FormLayout puts labels to the LEFT, in
 * one column whose width is the longest label, and gives every child its own row. Those are not
 * the same layout, and plan/27 §6 had already had to fight the second one to get an error message
 * to sit next to the field it answered (it put the message a row away, and the password meter's
 * row away from that). Label, field, message and hint are one object here, so they cannot be
 * separated by a layout again.
 *
 * NO STRINGS. Every word this draws is passed in, because the builder's lupdate is built without
 * QML support and a qsTr() in this file would reach no catalogue (plan/27 §1). The one thing it
 * does decide is which of `error` and `hint` to show, and it shows the error.
 *
 * NOT a QQC2.TextField with a custom background, for the reason every hand-drawn control on these
 * pages gives: qqc2-desktop-style draws Breeze's field — its radius, its height, its focus ring —
 * whatever Kirigami.Theme says about colour. What IS kept is a real TextInput underneath, so
 * selection, the clipboard, the input method and accessibility are Qt's and not a reimplementation.
 */
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: field

    property Theme ds
    property string label
    /*! Shown under the field when `error` is empty. */
    property string hint
    /*! Shown under the field INSTEAD of the hint, and turns the border red. */
    property string error
    property string placeholder
    property alias text: input.text
    /*! Draws the value in the mono face — for the things the design system sets in mono:
     *  usernames, host names, domains, server addresses. */
    property bool mono: false
    property bool echoPassword: false
    property alias inputItem: input

    signal edited(string value)

    spacing: field.ds.space2
    // `enabled` already stops the TextInput taking focus and the clipboard working; this is the
    // half Qt does not do for a hand-drawn control. 0.5 is the design system's disabled state.
    opacity: field.enabled ? 1 : 0.5

    // A FIELD IS AS WIDE AS ITS LAYOUT SAYS AND NEVER AS WIDE AS ITS WORDS. Both Texts in this
    // component take their width from the cell and contribute NOTHING back to it, which is what
    // `Layout.preferredWidth: 0` means here — not "zero wide" (fillWidth takes the cell) but "do
    // not ask for a width of your own".
    //
    // THE BUG THAT PUT THEM HERE. LocalForm lays its fields out in a two-column GridLayout, and a
    // grid column is at least as wide as the widest implicit width in it. A Text's implicitWidth
    // is its text on ONE line — wrapMode changes how it draws, not what it asks for — so the
    // moment libpwquality answered "The password is shorter than 8 characters" the password cell
    // asked for a column wide enough to set that sentence unwrapped, the grid granted as much of
    // it as it could, and the OTHER column shrank to pay for it. Every field on the page moved,
    // and moved back when the message cleared: the form visibly rearranged itself while somebody
    // was typing into it.
    //
    // The label gets the same treatment for the same reason and one more: it already carries
    // `elide`, which is a statement that this label may be clipped — a component cannot ask to be
    // elided and also demand the width that would stop it being elided.
    Text {
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        visible: field.label.length > 0
        text: field.label
        color: field.ds.textStrong
        elide: Text.ElideRight
        font.family: field.ds.fontSans
        font.pixelSize: field.ds.textSm
        font.weight: field.ds.weightMedium
    }

    Rectangle {
        id: box

        Layout.fillWidth: true
        implicitHeight: field.ds.controlHeightMd
        radius: field.ds.radiusMd
        color: field.ds.surfaceCard
        border.width: field.ds.borderWidth
        // The design system's three field states, in the order they win: invalid beats focus
        // beats hover. An invalid field that looked focused would be telling the user the thing
        // they just typed is fine.
        border.color: field.error.length > 0
            ? field.ds.statusDanger
            : (input.activeFocus
                ? field.ds.accent
                : (boxHover.hovered ? field.ds.borderStrong : field.ds.borderDefault))

        Behavior on border.color {
            ColorAnimation { duration: field.ds.durationBase }
        }

        HoverHandler {
            id: boxHover
            cursorShape: Qt.IBeamCursor
        }

        // The 3px focus ring, drawn OUTSIDE the box so it does not eat the padding. It is the
        // design system's --shadow-focus, which QML has no shadow for; a ring is the same signal
        // and costs no layer.
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            visible: input.activeFocus
            radius: field.ds.radiusMd + 3
            color: "transparent"
            border.width: 3
            border.color: field.error.length > 0
                ? field.ds.mix(field.ds.statusDanger, field.ds.surfaceCard, 0.3)
                : field.ds.mix(field.ds.accent, field.ds.surfaceCard, 0.4)
        }

        TextInput {
            id: input

            anchors.fill: parent
            anchors.leftMargin: field.ds.space3
            anchors.rightMargin: field.ds.space3
            verticalAlignment: TextInput.AlignVCenter
            clip: true
            selectByMouse: true
            color: field.ds.textStrong
            selectionColor: field.ds.accent
            selectedTextColor: field.ds.accentOn
            echoMode: field.echoPassword ? TextInput.Password : TextInput.Normal
            passwordCharacter: "•"
            font.family: field.mono ? field.ds.fontMono : field.ds.fontSans
            font.pixelSize: field.ds.textBase

            // `onTextEdited`, never `onTextChanged`: the C++ side writes this property back, and
            // a handler on textChanged would push that write straight back into C++ — the ring
            // every one of these pages is careful not to close.
            onTextEdited: field.edited(input.text)

            Accessible.role: Accessible.EditableText
            Accessible.name: field.label
            Accessible.description: field.error.length > 0 ? field.error : field.hint

            Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                visible: input.text.length === 0 && !input.activeFocus
                text: field.placeholder
                color: field.ds.textSubtle
                font: input.font
            }
        }
    }

    // ONE SLOT FOR BOTH, which is plan/27 §6's finding kept: the message that answers a field
    // belongs against that field and nowhere else. The error wins when there is one, because a
    // hint under a red border is advice about a problem it is not describing.
    Text {
        Layout.fillWidth: true
        // See the label above: the message answers the field, it does not size it.
        Layout.preferredWidth: 0
        visible: text.length > 0
        text: field.error.length > 0 ? field.error : field.hint
        color: field.error.length > 0 ? field.ds.statusDanger : field.ds.textMuted
        wrapMode: Text.WordWrap
        font.family: field.ds.fontSans
        font.pixelSize: field.ds.textXs
    }
}
