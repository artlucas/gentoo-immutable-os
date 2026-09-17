/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Mode 1: one local account, which is what Calamares' stock users page created and what this
 * mode still creates — `wheel`, `video` and `pipewire`, the subuid range rootless podman needs,
 * and sudo and polkit through the groups the image already ships rules for.
 *
 * Two behaviours here are stock users' and are kept on purpose: typing a full name guesses the
 * username (in AccountsConfig::setFullName, until the person edits the username themselves), and
 * the password meter is libpwquality's own 0..100 score rather than a rule of our own.
 *
 * One is new (plan/26 §4): the auto-login checkbox under the password, off by default. The
 * installed machine greets unless the person standing here says otherwise — the same default
 * plan/21 shipped, now with a way to ask for the other thing.
 *
 * THE ERROR IS GLUED TO ITS FIELD (plan/27 §6), and since plan/28 it cannot come unglued: a
 * Kirigami.FormLayout gave every child its own row and its own gap, which put the red password
 * message a row — and, whenever a password existed, the score meter's row — away from the field
 * it answered. The layout is now a two-column grid of shared Field objects, and label, value,
 * error and hint are one object inside each cell. There is no layout left that could separate
 * them.
 *
 * No qsTr() anywhere in this file: every word is an AccountsConfig tr() property, because the
 * builder's lupdate is built without QML support and a qsTr() here would never reach the
 * branding catalogue (plan/25 §4, applied here by plan/27 §1). The placeholders are the one
 * deliberate exception — "Ada Lovelace" and "ada" are proper nouns, kept as literals for the
 * same reason apps.conf keeps application names untranslated.
 */
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: form

    required property Theme ds

    spacing: form.ds.space6

    GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: form.ds.space5 - 2
        rowSpacing: form.ds.space5 - 2

        Field {
            Layout.fillWidth: true
            ds: form.ds
            label: accounts.realNameLabel
            text: accounts.fullName
            placeholder: "Ada Lovelace"
            onEdited: function (value) { accounts.fullName = value; }
        }

        Field {
            Layout.fillWidth: true
            ds: form.ds
            label: accounts.loginNameLabel
            text: accounts.loginName
            error: accounts.loginNameMessage
            placeholder: "ada"
            // A user name is an identifier, and the design system sets identifiers in mono.
            mono: true
            onEdited: function (value) { accounts.loginName = value; }
        }

        // THE METER IS PART OF THE PASSWORD CELL, not a row of its own. It is libpwquality's own
        // 0..100 score, and it belongs under the field it scores — which is what a form layout
        // could not be made to promise.
        ColumnLayout {
            Layout.fillWidth: true
            spacing: form.ds.space2

            Field {
                id: passwordField

                Layout.fillWidth: true
                ds: form.ds
                label: accounts.passwordLabel
                text: accounts.password
                error: accounts.passwordMessage
                echoPassword: true
                onEdited: function (value) { accounts.password = value; }
            }

            // The design system's Progress track: 8px, pill, sunken ground, accent fill.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 8
                visible: accounts.password.length > 0
                radius: form.ds.radiusPill
                color: form.ds.surfaceSunken

                Rectangle {
                    width: parent.width * Math.max(0, Math.min(100, accounts.passwordScore)) / 100
                    height: parent.height
                    radius: form.ds.radiusPill
                    // The score's own colour, because a full bar in the accent would say "good"
                    // about a password libpwquality scored 20. The thresholds are the meter's,
                    // not a policy: the policy is the message above, which C++ owns.
                    color: accounts.passwordScore >= 70
                        ? form.ds.statusSuccess
                        : (accounts.passwordScore >= 40 ? form.ds.statusWarning
                                                        : form.ds.statusDanger)

                    Behavior on width {
                        NumberAnimation { duration: form.ds.durationSlow }
                    }
                }
            }
        }

        Field {
            Layout.fillWidth: true
            ds: form.ds
            label: accounts.passwordRepeatLabel
            text: accounts.passwordRepeat
            // The mismatch is only worth saying once something has been typed to mismatch with.
            error: accounts.passwordRepeat.length > 0 && !accounts.passwordsMatch
                ? accounts.passwordsDifferText
                : ""
            echoPassword: true
            onEdited: function (value) { accounts.passwordRepeat = value; }
        }

        ComputerNameField {
            Layout.fillWidth: true
            ds: form.ds
        }
    }

    // Not a binding on `checked`, for the reason every control in this family gives: C++ is the
    // source of truth — it is what publish() reads — and the Connections below puts back what it
    // says. Since plan/28 the box is drawn rather than a QQC2.CheckBox, because the style would
    // paint Breeze's; the state still lives in exactly one place.
    RowLayout {
        Layout.fillWidth: true
        spacing: form.ds.space2

        Rectangle {
            id: autoLoginBox

            property bool checked: accounts.autoLogin

            Layout.alignment: Qt.AlignVCenter
            implicitWidth: 20
            implicitHeight: 20
            radius: form.ds.radiusSm
            color: autoLoginBox.checked ? form.ds.accent : form.ds.surfaceCard
            border.width: form.ds.borderWidthStrong
            border.color: autoLoginBox.checked ? form.ds.accent : form.ds.borderStrong

            Text {
                anchors.centerIn: parent
                visible: autoLoginBox.checked
                text: "✓"
                color: form.ds.accentOn
                font.family: form.ds.fontSans
                font.pixelSize: form.ds.textXs
                font.weight: form.ds.weightBold
            }

            Connections {
                target: accounts
                function onAutoLoginChanged() {
                    autoLoginBox.checked = accounts.autoLogin;
                }
            }
        }

        Text {
            Layout.fillWidth: true
            text: accounts.autoLoginLabel
            color: form.ds.textBody
            wrapMode: Text.WordWrap
            font.family: form.ds.fontSans
            font.pixelSize: form.ds.textBase
        }

        // ONE HIT TARGET FOR BOX AND LABEL (plan/27 §7): the words beside a mark are words
        // somebody clicks. It covers the whole row rather than sitting beside either.
        HoverHandler { cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: accounts.autoLogin = !accounts.autoLogin }

        Accessible.role: Accessible.CheckBox
        Accessible.name: accounts.autoLoginLabel
        Accessible.checked: accounts.autoLogin
        Accessible.onToggleAction: accounts.autoLogin = !accounts.autoLogin
    }
}
