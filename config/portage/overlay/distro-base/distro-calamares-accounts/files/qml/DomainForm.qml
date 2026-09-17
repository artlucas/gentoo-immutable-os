/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Mode 3: Active Directory (plan/18, plan/21 §1).
 *
 * TWO THINGS THIS FORM HAS THAT CALAMARES' OWN AD CHECKBOX COULD NOT.
 *
 * The first is the Advanced section. `<id>-domain join` has always taken --ou, --admin-group and
 * --computer-name; plan/18 §7.1 recorded that "only the page cannot express them", because the
 * page was upstream's and its four fields were fixed. This page is ours.
 *
 * The second is that the local administrator is presented as what it is. Calamares' checkbox made
 * the local account look like something you filled in *as well*, for no stated reason. It is the
 * way back in when the domain controller is unreachable, it owns wheel and polkit, and it holds
 * the subuid range rootless podman needs — so it says so, and its username defaults to `admin`
 * because it is not the account anyone signs in with day to day.
 *
 * `Check domain` is advisory and never blocks: a failed join cannot brick this mode, because the
 * local administrator is created either way (plan/18 §7.4).
 *
 * WHY THIS ONE FORM IS TWO COLUMNS AND THE OTHER TWO ARE NOT.
 *
 * It is the only mode that asks for two accounts at once — a domain to join and a local
 * administrator to keep. Measured, by rendering this file against the medium's own Qt, Kirigami
 * and qqc2-desktop-style in the viewport Calamares gives a view module — 710x536, the 900x600
 * branding window less the 190px sidebar and the 64px navigation bar (CalamaresWindow.cpp:503
 * and :509):
 *
 *     one column    490px at rest, 590px with Advanced open  → the disclosure brings back the
 *                                                              scrollbar on its own
 *     two columns   331px at rest, 481px in the worst state anyone can reach: Advanced open, a
 *                   failed domain check and three validation errors at once
 *
 * Local and managed are 258px and 261px in one column, and that is why they stay that way: a
 * two-column form with four fields in it is a layout looking for a problem, and this one splits
 * along a seam that was already there.
 *
 * The split is not cosmetic. Left is the domain and the machine's relationship to it; right is the
 * account that survives the domain being unreachable. Reading them side by side is the thing the
 * old checkbox could not say: these are two separate answers, and you are giving both.
 *
 * `twoColumns` falls back to one column below 32 gridUnits, which is font size, not pixels — a
 * large-text or small-screen medium stacks instead of clipping, and then scrolls, which is the
 * right failure. Field widths are `Layout.preferredWidth` rather than the control's own implicit
 * width so that Kirigami.FormLayout's `wideMode` test (`width >= lay.wideImplicitWidth`,
 * FormLayout.qml:75) still passes inside a half-width column: without it the labels jump above
 * their fields and each row costs twice the height the split just saved.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

ColumnLayout {
    id: form

    spacing: Kirigami.Units.largeSpacing

    readonly property bool twoColumns: form.width >= Kirigami.Units.gridUnit * 32
    readonly property int fieldWidth: Kirigami.Units.gridUnit * 9

    GridLayout {
        Layout.fillWidth: true
        columns: form.twoColumns ? 2 : 1
        columnSpacing: Kirigami.Units.gridUnit
        rowSpacing: Kirigami.Units.largeSpacing

        // ---- left: the domain ------------------------------------------------------------
        ColumnLayout {
            Layout.fillWidth: true
            // Equal halves. Two fillWidth items in a GridLayout share the surplus in proportion
            // to their preferred widths, so equal (and small) preferred widths is what makes the
            // columns the same size regardless of which one has the longer labels in it.
            Layout.preferredWidth: 1
            Layout.alignment: Qt.AlignTop
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Heading {
                level: 4
                text: accounts.domainHeading
            }

            Kirigami.FormLayout {
                Layout.fillWidth: true

                QQC2.TextField {
                    Kirigami.FormData.label: accounts.domainNameLabel
                    Layout.fillWidth: true
                    Layout.preferredWidth: form.fieldWidth
                    text: accounts.domainName
                    onTextEdited: accounts.domainName = text
                    placeholderText: "corp.example.com"
                }

                QQC2.TextField {
                    Kirigami.FormData.label: accounts.joinAccountLabel
                    Layout.fillWidth: true
                    Layout.preferredWidth: form.fieldWidth
                    text: accounts.joinUser
                    onTextEdited: accounts.joinUser = text
                    placeholderText: "Administrator"
                }

                Kirigami.PasswordField {
                    Kirigami.FormData.label: accounts.joinPasswordLabel
                    Layout.fillWidth: true
                    Layout.preferredWidth: form.fieldWidth
                    text: accounts.joinPassword
                    onTextEdited: accounts.joinPassword = text
                }

                // What Calamares' own page called the IP field, and it does one small specific
                // thing: it puts "<address> <domain>" in the target's /etc/hosts before the join,
                // for a domain controller that is reachable when DNS is not yet. The label lost
                // the word "address" when this became a half-width column; the placeholder says
                // what goes in it, which is where that word was doing more good anyway.
                QQC2.TextField {
                    Kirigami.FormData.label: accounts.dcLabel
                    Layout.fillWidth: true
                    Layout.preferredWidth: form.fieldWidth
                    text: accounts.dcAddress
                    onTextEdited: accounts.dcAddress = text
                    placeholderText: accounts.dcPlaceholder
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing

                QQC2.Button {
                    text: accounts.checkDomainLabel
                    icon.name: "network-connect"
                    enabled: !accounts.verifyRunning
                    onClicked: accounts.verifyDomain()
                }

                QQC2.BusyIndicator {
                    running: accounts.verifyRunning
                    visible: running
                    implicitWidth: Kirigami.Units.gridUnit * 1.5
                    implicitHeight: implicitWidth
                }
            }

            Kirigami.InlineMessage {
                Layout.fillWidth: true
                visible: accounts.verifyOk || accounts.verifyFailed
                // Information, not Error, when the check fails: the install will finish either
                // way, and an alarm here would say the opposite of what the sentence below it
                // says.
                type: accounts.verifyOk ? Kirigami.MessageType.Positive : Kirigami.MessageType.Information
                text: accounts.verifyMessage
            }
        }

        // ---- right: the way back in ------------------------------------------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.alignment: Qt.AlignTop
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Heading {
                level: 4
                text: accounts.adminHeading
            }

            QQC2.Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                opacity: 0.75
                font: Kirigami.Theme.smallFont
                text: accounts.adminIntroText
            }

            Kirigami.FormLayout {
                Layout.fillWidth: true

                // The glued field-and-error rows LocalForm explains (plan/27 §6): one form row,
                // spacing 0, the message the field's immediately following sibling.
                ColumnLayout {
                    Kirigami.FormData.label: accounts.loginNameLabel

                    spacing: 0

                    QQC2.TextField {
                        id: adminLogin

                        Layout.fillWidth: true
                        Layout.preferredWidth: form.fieldWidth
                        text: accounts.loginName
                        onTextEdited: accounts.loginName = text
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
                        id: adminPassword

                        Layout.fillWidth: true
                        Layout.preferredWidth: form.fieldWidth
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
                        Layout.fillWidth: true
                        Layout.preferredWidth: form.fieldWidth
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
            }
        }
    }

    // ---- below both columns ---------------------------------------------------------------
    // Advanced is full width rather than inside the domain column because its labels are the
    // longest on the page: in a half-width column they would force the narrow-mode flip described
    // above, and each of these three rows would cost twice the height the split just saved.
    QQC2.Button {
        id: advancedToggle
        checkable: true
        flat: true
        text: accounts.advancedLabel
        icon.name: checked ? "go-down-symbolic" : "go-next-symbolic"
    }

    Kirigami.FormLayout {
        Layout.fillWidth: true
        visible: advancedToggle.checked

        QQC2.TextField {
            Kirigami.FormData.label: accounts.computerOuLabel
            Layout.fillWidth: true
            Layout.preferredWidth: form.fieldWidth
            text: accounts.computerOu
            onTextEdited: accounts.computerOu = text
            placeholderText: "OU=Laptops,DC=corp,DC=example,DC=com"
        }

        QQC2.TextField {
            Kirigami.FormData.label: accounts.adminGroupLabel
            Layout.fillWidth: true
            Layout.preferredWidth: form.fieldWidth
            text: accounts.adminGroup
            onTextEdited: accounts.adminGroup = text
            placeholderText: "Domain Admins"
        }

        QQC2.TextField {
            Kirigami.FormData.label: accounts.computerAccountLabel
            Layout.fillWidth: true
            Layout.preferredWidth: form.fieldWidth
            text: accounts.computerName
            onTextEdited: accounts.computerName = text
            placeholderText: accounts.computerAccountPlaceholder
        }
    }

    Kirigami.Separator {
        Layout.fillWidth: true
    }

    // The machine's own name, and it belongs to neither column: it is the hostname in every mode,
    // it is what the computer account defaults to above, and putting it under one of the two
    // accounts would have implied it was part of that account.
    Kirigami.FormLayout {
        Layout.fillWidth: true

        ComputerNameField {
            Layout.preferredWidth: form.fieldWidth
        }
    }
}
