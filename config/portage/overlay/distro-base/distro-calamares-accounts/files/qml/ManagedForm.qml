/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Mode 2: managed (plan/19, plan/21 §3; repainted in plan/28).
 *
 * THIS IS THE ONE FORM ON THE PAGE WITH A BUTTON, and the button is why the mode works at all.
 * Pressing it runs the real enrolment — `<id>-managed enroll --root /run/<id>-accounts/enroll` —
 * against the real control plane, before the disk has been touched. Next stays disabled until it
 * succeeds, which is a rule the rest of this installer does not have and this mode cannot do
 * without: it creates no local account, so an install that finished with a failed enrolment would
 * hand somebody a machine with nothing to log into.
 *
 * The four visible states are AccountsConfig.ActionState — Idle, Running, Succeeded, Failed —
 * read here through the named booleans enrolRunning / enrolSucceeded / enrolFailed rather than
 * by number, because a context property cannot spell its own enumerators. The message in the
 * last two is the CLIENT'S OWN, not a translation of an exit code: "that enrolment code has
 * already been used" says more than anything this file could infer.
 *
 * No qsTr() anywhere in this file: every word is an AccountsConfig tr() property (plan/27 §1).
 * The placeholder is the one deliberate exception — "K7QF-9M2B" is a shape, not a sentence.
 */
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: form

    required property Theme ds

    spacing: form.ds.space5

    Text {
        Layout.fillWidth: true
        visible: accounts.organisationHint.length > 0
        text: accounts.organisationHint
        color: form.ds.textBody
        wrapMode: Text.WordWrap
        font.family: form.ds.fontSans
        font.pixelSize: form.ds.textSm
        lineHeight: form.ds.leadingNormal
        lineHeightMode: Text.ProportionalHeight
    }

    // THE ENROLMENT PANEL. The design system's inset — grey on the page's white — because these
    // two fields and the button under them are one transaction, and the panel is what says so.
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: enrolBody.implicitHeight + 2 * form.ds.space6
        radius: form.ds.radiusLg
        color: form.ds.surfacePage
        border.width: form.ds.borderWidth
        border.color: form.ds.borderSubtle

        ColumnLayout {
            id: enrolBody

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: form.ds.space6
            spacing: form.ds.space5

            Text {
                Layout.fillWidth: true
                text: accounts.enrolmentCodeLabel.toUpperCase()
                color: form.ds.textMuted
                elide: Text.ElideRight
                font.family: form.ds.fontMono
                font.pixelSize: 11
                font.letterSpacing: form.ds.tracking(form.ds.trackingCaps, 11)
            }

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: form.ds.space5 - 2
                rowSpacing: form.ds.space5 - 2

                Field {
                    Layout.fillWidth: true
                    ds: form.ds
                    label: accounts.enrolmentCodeLabel
                    text: accounts.enrolmentCode
                    placeholder: "K7QF-9M2B"
                    mono: true
                    enabled: !accounts.enrolRunning
                    onEdited: function (value) { accounts.enrolmentCode = value; }
                }

                ComputerNameField {
                    Layout.fillWidth: true
                    ds: form.ds
                    enabled: !accounts.enrolRunning
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: form.ds.space3 + 2

                Button {
                    ds: form.ds
                    variant: "secondary"
                    size: "sm"
                    label: accounts.enrolFailed ? accounts.tryAgainLabel
                                                : accounts.checkAndContinueLabel
                    enabled: !accounts.enrolRunning && accounts.enrolmentCode.length > 0
                        && accounts.hostnameValid
                    onClicked: accounts.checkAndEnrol()
                }

                // The design system's only looped animation is a spinner, and this is the one
                // place in the installer that waits on a network round trip with nothing else to
                // show. Three dots that fade in turn, at the system's own 150ms.
                Row {
                    visible: accounts.enrolRunning
                    spacing: 4

                    Repeater {
                        model: 3

                        Rectangle {
                            required property int index

                            width: 6
                            height: 6
                            radius: 3
                            color: form.ds.accent

                            SequentialAnimation on opacity {
                                running: accounts.enrolRunning
                                loops: Animation.Infinite

                                PauseAnimation { duration: index * 160 }
                                NumberAnimation { to: 1.0; duration: 160 }
                                NumberAnimation { to: 0.25; duration: 160 }
                                PauseAnimation { duration: (2 - index) * 160 }
                            }
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    visible: accounts.enrolRunning
                    text: accounts.enrolMessage
                    color: form.ds.textMuted
                    elide: Text.ElideRight
                    font.family: form.ds.fontMono
                    font.pixelSize: form.ds.textXs
                }
            }
        }
    }

    // The verdict, in the design system's success and danger tones. It was a
    // Kirigami.InlineMessage, which paints its own Breeze box and its own Breeze icon.
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: enrolVerdict.implicitHeight + 2 * form.ds.space3
        visible: accounts.enrolSucceeded || accounts.enrolFailed
        radius: form.ds.radiusMd
        color: accounts.enrolSucceeded ? form.ds.statusSuccessBg : form.ds.statusDangerBg
        border.width: form.ds.borderWidth
        border.color: accounts.enrolSucceeded
            ? form.ds.mix(form.ds.statusSuccess, form.ds.statusSuccessBg, 0.3)
            : form.ds.mix(form.ds.statusDanger, form.ds.statusDangerBg, 0.3)

        Text {
            id: enrolVerdict

            anchors.fill: parent
            anchors.margins: form.ds.space3
            anchors.leftMargin: form.ds.space4
            anchors.rightMargin: form.ds.space4
            text: accounts.enrolMessage
            color: form.ds.textBody
            wrapMode: Text.WordWrap
            font.family: form.ds.fontSans
            font.pixelSize: form.ds.textSm
            lineHeight: form.ds.leadingNormal
            lineHeightMode: Text.ProportionalHeight
        }
    }

    // Named, because "3 people" is a number and "Ada, Grace and Katherine" is a machine somebody
    // recognises. This is also the check that a successful enrolment is not enough: a bundle that
    // granted nobody leaves this list empty and Next disabled.
    Text {
        Layout.fillWidth: true
        visible: accounts.enrolSucceeded && accounts.grantedUsers.length > 0
        text: accounts.grantedAccountsText.arg(accounts.grantedUsers.join(", "))
        color: form.ds.textMuted
        wrapMode: Text.WordWrap
        font.family: form.ds.fontSans
        font.pixelSize: form.ds.textSm
    }

    Text {
        Layout.fillWidth: true
        visible: !accounts.enrolSucceeded
        text: accounts.managedIntroText
        color: form.ds.textMuted
        wrapMode: Text.WordWrap
        font.family: form.ds.fontSans
        font.pixelSize: form.ds.textSm
        lineHeight: form.ds.leadingNormal
        lineHeightMode: Text.ProportionalHeight
    }
}
