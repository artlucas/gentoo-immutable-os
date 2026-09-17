/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Mode 2: managed (plan/19, plan/21 §3).
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
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: form

    spacing: Kirigami.Units.largeSpacing

    QQC2.Label {
        Layout.fillWidth: true
        visible: accounts.organisationHint.length > 0
        text: accounts.organisationHint
        wrapMode: Text.WordWrap
    }

    Kirigami.FormLayout {
        Layout.fillWidth: true

        QQC2.TextField {
            id: codeField
            Kirigami.FormData.label: accounts.enrolmentCodeLabel
            text: accounts.enrolmentCode
            onTextEdited: accounts.enrolmentCode = text
            placeholderText: "K7QF-9M2B"
            enabled: !accounts.enrolRunning
        }

        ComputerNameField {
            enabled: !accounts.enrolRunning
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        QQC2.Button {
            text: accounts.enrolFailed ? accounts.tryAgainLabel : accounts.checkAndContinueLabel
            icon.name: "network-connect"
            enabled: !accounts.enrolRunning && accounts.enrolmentCode.length > 0
                && accounts.hostnameValid
            onClicked: accounts.checkAndEnrol()
        }

        QQC2.BusyIndicator {
            running: accounts.enrolRunning
            visible: running
            implicitWidth: Kirigami.Units.gridUnit * 1.5
            implicitHeight: implicitWidth
        }

        QQC2.Label {
            Layout.fillWidth: true
            visible: accounts.enrolRunning
            text: accounts.enrolMessage
            elide: Text.ElideRight
        }
    }

    Kirigami.InlineMessage {
        Layout.fillWidth: true
        visible: accounts.enrolSucceeded || accounts.enrolFailed
        type: accounts.enrolSucceeded ? Kirigami.MessageType.Positive : Kirigami.MessageType.Error
        text: accounts.enrolMessage
    }

    // Named, because "3 people" is a number and "Ada, Grace and Katherine" is a machine somebody
    // recognises. This is also the check that a successful enrolment is not enough: a bundle that
    // granted nobody leaves this list empty and Next disabled.
    QQC2.Label {
        Layout.fillWidth: true
        visible: accounts.enrolSucceeded && accounts.grantedUsers.length > 0
        wrapMode: Text.WordWrap
        opacity: 0.75
        font: Kirigami.Theme.smallFont
        text: accounts.grantedAccountsText.arg(accounts.grantedUsers.join(", "))
    }

    QQC2.Label {
        Layout.fillWidth: true
        visible: !accounts.enrolSucceeded
        wrapMode: Text.WordWrap
        opacity: 0.75
        font: Kirigami.Theme.smallFont
        text: accounts.managedIntroText
    }
}
