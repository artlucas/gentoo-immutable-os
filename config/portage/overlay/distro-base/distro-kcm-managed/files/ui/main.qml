/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * The System Settings page for managed mode (plan/19 §7.2).
 *
 * Unlike the standalone QML app this replaces, i18n() WORKS here: the KCM is loaded by a C++
 * host that installs a KLocalizedContext on the engine, which is exactly what the bare qml6
 * runtime does not do. The standalone app's strings had to be unwrapped for that reason, and
 * getting them back is one of the things the Phase D overlay buys.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: page

    property var st: kcm.status
    readonly property bool enrolled: st && st.enrolled === true

    // §8.8 again, in the surface a person actually opens: the page is readable by the person
    // being managed, and refreshing it needs no authentication.
    Component.onCompleted: kcm.refresh()

    Connections {
        target: kcm
        function onOperationFinished(ok, message) {
            if (!ok && message.length === 0) {
                return; // the polkit prompt was dismissed; not an error worth reporting
            }
            resultMessage.type = ok ? Kirigami.MessageType.Positive : Kirigami.MessageType.Error
            resultMessage.text = ok
                ? i18n("Done.")
                : message
            resultMessage.visible = true
        }
    }

    ColumnLayout {
        spacing: Kirigami.Units.largeSpacing

        Kirigami.InlineMessage {
            id: resultMessage
            Layout.fillWidth: true
            visible: false
            showCloseButton: true
        }

        // The control plane WILL be down (§8.6), and when it is the device keeps authenticating
        // its users and keeps enforcing its policy. So this is information, never an alarm.
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.enrolled && page.st.last_error
            type: Kirigami.MessageType.Information
            text: i18n("This computer last spoke to %1 on %2. Everything still works — the settings below stay in force until it can reach it again.",
                       page.st.org || i18n("your organisation"),
                       page.st.last_success || i18n("an unknown date"))
        }

        Kirigami.Heading {
            Layout.fillWidth: true
            level: 2
            text: page.enrolled
                  ? i18n("Managed by %1", page.st.org || i18n("your organisation"))
                  : i18n("This computer is not managed")
        }

        QQC2.Label {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            visible: !page.enrolled
            text: i18n("Enrolling lets an organisation — a household or a small business — create the accounts on this computer and decide what they are allowed to do. Accounts already on this computer are not affected, and you can leave at any time.")
        }

        Kirigami.FormLayout {
            Layout.fillWidth: true
            visible: !page.enrolled

            QQC2.TextField {
                id: codeField
                enabled: !kcm.busy
                Kirigami.FormData.label: i18n("Enrolment code:")
                placeholderText: i18n("K7QF-9M2B")
                // Typed by a human off a phone screen (§5.2), so it is short and
                // case-insensitive; upper-casing here saves an error the server would
                // otherwise have to explain.
                onTextChanged: {
                    var up = text.toUpperCase();
                    if (up !== text) text = up;
                }
                onAccepted: if (enrolButton.enabled) enrolButton.clicked()
            }

            QQC2.TextField {
                id: nameField
                enabled: !kcm.busy
                Kirigami.FormData.label: i18n("Name for this computer:")
                placeholderText: i18n("kitchen-pc")
            }
        }

        Kirigami.FormLayout {
            Layout.fillWidth: true
            visible: page.enrolled

            QQC2.Label {
                Kirigami.FormData.label: i18n("Last checked:")
                text: page.st.last_success || i18n("never")
            }
            QQC2.Label {
                Kirigami.FormData.label: i18n("Accounts on this computer:")
                text: (page.st.users && page.st.users.length)
                      ? page.st.users.join(", ") : i18n("none yet")
            }
            QQC2.Label {
                Kirigami.FormData.label: i18n("Settings version:")
                text: page.st.bundle_serial !== undefined && page.st.bundle_serial !== null
                      ? String(page.st.bundle_serial) : i18n("none")
            }
            QQC2.Label {
                Kirigami.FormData.label: i18n("This computer is known as:")
                text: page.st.device_id || ""
            }
        }

        // Monitoring is visible or it is not consented to (§8.8). Nothing collects anything in
        // v1, and the page says so rather than staying quiet about it.
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            visible: page.enrolled
            type: Kirigami.MessageType.Information
            text: i18n("Screen time and activity monitoring are not enabled on this computer. Nothing about how you use it is recorded or sent.")
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            QQC2.Button {
                id: enrolButton
                visible: !page.enrolled
                enabled: !kcm.busy && codeField.text.length >= 4
                icon.name: "cloud-upload"
                text: i18n("Enrol this computer")
                onClicked: kcm.enroll(codeField.text, nameField.text)
            }
            QQC2.Button {
                visible: page.enrolled
                enabled: !kcm.busy
                icon.name: "view-refresh"
                text: i18n("Check for changes now")
                onClicked: kcm.syncNow()
            }
            QQC2.BusyIndicator {
                running: kcm.busy
                visible: kcm.busy
                Layout.preferredHeight: Kirigami.Units.gridUnit * 1.5
                Layout.preferredWidth: Kirigami.Units.gridUnit * 1.5
            }
            Item { Layout.fillWidth: true }
            QQC2.Button {
                visible: page.enrolled
                enabled: !kcm.busy
                icon.name: "dialog-cancel"
                text: i18n("Leave…")
                onClicked: leaveDialog.open()
            }
        }
    }

    // §8.9's promise, stated where someone can read it rather than only in a design document:
    // a household that stops paying does not lose its computers.
    Kirigami.PromptDialog {
        id: leaveDialog
        title: i18n("Leave managed mode?")
        subtitle: i18n("Every managed account stays on this computer as an ordinary local account — same name, same password, same files. This computer simply stops receiving settings from %1.",
                       page.st.org || i18n("your organisation"))
        standardButtons: Kirigami.Dialog.NoButton
        customFooterActions: [
            Kirigami.Action {
                text: i18n("Leave")
                icon.name: "dialog-ok"
                onTriggered: {
                    leaveDialog.close();
                    kcm.leave();
                }
            },
            Kirigami.Action {
                text: i18n("Cancel")
                icon.name: "dialog-cancel"
                onTriggered: leaveDialog.close()
            }
        ]
    }
}
