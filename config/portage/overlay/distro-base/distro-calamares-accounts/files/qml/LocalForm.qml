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
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Kirigami.FormLayout {
    id: form

    QQC2.TextField {
        Kirigami.FormData.label: qsTr("Your name:")
        text: accounts.fullName
        onTextEdited: accounts.fullName = text
        placeholderText: qsTr("Ada Lovelace")
    }

    QQC2.TextField {
        id: loginField
        Kirigami.FormData.label: qsTr("Username:")
        text: accounts.loginName
        onTextEdited: accounts.loginName = text
        placeholderText: qsTr("ada")
    }

    QQC2.Label {
        visible: accounts.loginNameMessage.length > 0
        text: accounts.loginNameMessage
        wrapMode: Text.WordWrap
        Layout.maximumWidth: loginField.width
        color: Kirigami.Theme.negativeTextColor
        font: Kirigami.Theme.smallFont
    }

    Kirigami.PasswordField {
        id: passwordField
        Kirigami.FormData.label: qsTr("Password:")
        text: accounts.password
        onTextEdited: accounts.password = text
    }

    QQC2.ProgressBar {
        Layout.maximumWidth: passwordField.width
        from: 0
        to: 100
        value: accounts.passwordScore
        visible: accounts.password.length > 0
    }

    QQC2.Label {
        visible: accounts.passwordMessage.length > 0
        text: accounts.passwordMessage
        wrapMode: Text.WordWrap
        Layout.maximumWidth: passwordField.width
        color: Kirigami.Theme.negativeTextColor
        font: Kirigami.Theme.smallFont
    }

    Kirigami.PasswordField {
        Kirigami.FormData.label: qsTr("Repeat password:")
        text: accounts.passwordRepeat
        onTextEdited: accounts.passwordRepeat = text
    }

    QQC2.Label {
        visible: accounts.passwordRepeat.length > 0 && !accounts.passwordsMatch
        text: qsTr("The two passwords are not the same.")
        color: Kirigami.Theme.negativeTextColor
        font: Kirigami.Theme.smallFont
    }

    // Not a binding on `checked`, for the reason every control in this family gives: a QQC2
    // control assigns `checked` imperatively when clicked, which breaks one. C++ is the source
    // of truth — it is what publish() reads — and the Connections below puts back what it says.
    QQC2.CheckBox {
        id: autoLoginBox

        Layout.topMargin: Kirigami.Units.smallSpacing
        text: qsTr("Log in automatically as this user")
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
