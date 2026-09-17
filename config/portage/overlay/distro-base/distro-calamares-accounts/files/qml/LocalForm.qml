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
 * THE ERROR IS GLUED TO ITS FIELD (plan/27 §6). A Kirigami.FormLayout gives every child its own
 * row and its own gap, which put the red password message a row — and, whenever a password
 * existed, the score meter's row — away from the field it answered. Each field and its message
 * are now ONE form row: a ColumnLayout with spacing 0 (the shape ComputerNameField has always
 * had), the message the immediately following sibling. Inside the password column the order is
 * field, error, meter: the error answers the field, the meter scores it, and only the meter
 * gets breathing room.
 *
 * No qsTr() anywhere in this file: every word is an AccountsConfig tr() property, because the
 * builder's lupdate is built without QML support and a qsTr() here would never reach the
 * branding catalogue (plan/25 §4, applied here by plan/27 §1). The placeholders are the one
 * deliberate exception — "Ada Lovelace" and "ada" are proper nouns, kept as literals for the
 * same reason apps.conf keeps application names untranslated.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: form

    QQC2.TextField {
        Kirigami.FormData.label: accounts.realNameLabel
        text: accounts.fullName
        onTextEdited: accounts.fullName = text
        placeholderText: "Ada Lovelace"
    }

    ColumnLayout {
        Kirigami.FormData.label: accounts.loginNameLabel

        spacing: 0

        QQC2.TextField {
            id: loginField

            Layout.fillWidth: true
            text: accounts.loginName
            onTextEdited: accounts.loginName = text
            placeholderText: "ada"
        }

        QQC2.Label {
            visible: accounts.loginNameMessage.length > 0
            text: accounts.loginNameMessage
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            color: Kirigami.Theme.negativeTextColor
            font: Kirigami.Theme.smallFont
        }
    }

    ColumnLayout {
        Kirigami.FormData.label: accounts.passwordLabel

        spacing: 0

        Kirigami.PasswordField {
            id: passwordField

            Layout.fillWidth: true
            text: accounts.password
            onTextEdited: accounts.password = text
        }

        QQC2.Label {
            visible: accounts.passwordMessage.length > 0
            text: accounts.passwordMessage
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            color: Kirigami.Theme.negativeTextColor
            font: Kirigami.Theme.smallFont
        }

        QQC2.ProgressBar {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            from: 0
            to: 100
            value: accounts.passwordScore
            visible: accounts.password.length > 0
        }
    }

    ColumnLayout {
        Kirigami.FormData.label: accounts.passwordRepeatLabel

        spacing: 0

        Kirigami.PasswordField {
            id: repeatField

            Layout.fillWidth: true
            text: accounts.passwordRepeat
            onTextEdited: accounts.passwordRepeat = text
        }

        QQC2.Label {
            visible: accounts.passwordRepeat.length > 0 && !accounts.passwordsMatch
            text: accounts.passwordsDifferText
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            color: Kirigami.Theme.negativeTextColor
            font: Kirigami.Theme.smallFont
        }
    }

    // Not a binding on `checked`, for the reason every control in this family gives: a QQC2
    // control assigns `checked` imperatively when clicked, which breaks one. C++ is the source
    // of truth — it is what publish() reads — and the Connections below puts back what it says.
    QQC2.CheckBox {
        id: autoLoginBox

        Layout.topMargin: Kirigami.Units.smallSpacing
        text: accounts.autoLoginLabel
        checked: accounts.autoLogin
        onToggled: accounts.autoLogin = autoLoginBox.checked

        Connections {
            target: accounts
            function onAutoLoginChanged() {
                autoLoginBox.checked = accounts.autoLogin;
            }
        }
    }

    Item {
        Kirigami.FormData.isSection: true
    }

    ComputerNameField {}
}
