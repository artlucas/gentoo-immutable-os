/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Mode 3: Active Directory (plan/18, plan/21 §1; repainted in plan/28).
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
 * WHAT plan/28 CHANGED IN THE LAYOUT, AND WHAT IT KEPT.
 *
 * The two panels are still two panels, and for the reason they always were: this is the only mode
 * that asks for two accounts at once, and reading them side by side is the thing the old checkbox
 * could not say — these are two separate answers, and you are giving both. Left is the domain and
 * the machine's relationship to it; right is the account that survives the domain being
 * unreachable.
 *
 * What went is Kirigami.FormLayout, and with it the measurement that used to live here. Those
 * numbers were about a layout whose labels sat to the LEFT of their fields, in a column as wide
 * as the longest one, with a `wideMode` flip that had to be defended with explicit field widths
 * or every row doubled in height. The design system puts labels ABOVE their fields, so a column
 * is as wide as its fields and nothing flips. `twoColumns` stays, in pixels rather than gridUnits
 * now that the type is not the unit of layout: below the threshold the two panels stack, which is
 * still the right failure.
 *
 * The panels are the design system's insets — grey on the page's white — which is also what now
 * says "these are two groups" without a heading having to carry it alone.
 *
 * No qsTr() anywhere in this file: every word is an AccountsConfig tr() property (plan/27 §1).
 * The placeholders are proper nouns and shapes, kept as literals.
 */
import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: form

    required property Theme ds

    spacing: form.ds.space5

    // Two panels side by side need room for two 40px fields and their labels; below that they
    // stack and the page scrolls, which is the right failure rather than clipping.
    readonly property bool twoColumns: form.width >= 640

    GridLayout {
        Layout.fillWidth: true
        columns: form.twoColumns ? 2 : 1
        columnSpacing: form.ds.space5 - 2
        rowSpacing: form.ds.space5 - 2

        // ---- left: the domain ------------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            // Equal halves. Two fillWidth items in a GridLayout share the surplus in proportion
            // to their preferred widths, so equal (and small) preferred widths is what makes the
            // columns the same size regardless of what is in them.
            Layout.preferredWidth: 1
            Layout.alignment: Qt.AlignTop
            implicitHeight: domainBody.implicitHeight + 2 * form.ds.space6
            radius: form.ds.radiusLg
            color: form.ds.surfacePage
            border.width: form.ds.borderWidth
            border.color: form.ds.borderSubtle

            ColumnLayout {
                id: domainBody

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: form.ds.space6
                spacing: form.ds.space5 - 2

                Text {
                    Layout.fillWidth: true
                    text: accounts.domainHeading.toUpperCase()
                    color: form.ds.textMuted
                    elide: Text.ElideRight
                    font.family: form.ds.fontMono
                    font.pixelSize: 11
                    font.letterSpacing: form.ds.tracking(form.ds.trackingCaps, 11)
                }

                Field {
                    Layout.fillWidth: true
                    ds: form.ds
                    label: accounts.domainNameLabel
                    text: accounts.domainName
                    placeholder: "corp.example.com"
                    mono: true
                    onEdited: function (value) { accounts.domainName = value; }
                }

                Field {
                    Layout.fillWidth: true
                    ds: form.ds
                    label: accounts.joinAccountLabel
                    text: accounts.joinUser
                    placeholder: "Administrator"
                    mono: true
                    onEdited: function (value) { accounts.joinUser = value; }
                }

                Field {
                    Layout.fillWidth: true
                    ds: form.ds
                    label: accounts.joinPasswordLabel
                    text: accounts.joinPassword
                    echoPassword: true
                    onEdited: function (value) { accounts.joinPassword = value; }
                }

                // What Calamares' own page called the IP field, and it does one small specific
                // thing: it puts "<address> <domain>" in the target's /etc/hosts before the join,
                // for a domain controller that is reachable when DNS is not yet. The label lost
                // the word "address" when this became a half-width column; the placeholder says
                // what goes in it, which is where that word was doing more good anyway.
                Field {
                    Layout.fillWidth: true
                    ds: form.ds
                    label: accounts.dcLabel
                    text: accounts.dcAddress
                    placeholder: accounts.dcPlaceholder
                    mono: true
                    onEdited: function (value) { accounts.dcAddress = value; }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: form.ds.space3

                    Button {
                        ds: form.ds
                        variant: "secondary"
                        size: "sm"
                        label: accounts.checkDomainLabel
                        enabled: !accounts.verifyRunning
                        onClicked: accounts.verifyDomain()
                    }

                    Row {
                        visible: accounts.verifyRunning
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
                                    running: accounts.verifyRunning
                                    loops: Animation.Infinite

                                    PauseAnimation { duration: index * 160 }
                                    NumberAnimation { to: 1.0; duration: 160 }
                                    NumberAnimation { to: 0.25; duration: 160 }
                                    PauseAnimation { duration: (2 - index) * 160 }
                                }
                            }
                        }
                    }
                }

                // Info, not danger, when the check fails: the install will finish either way, and
                // an alarm here would say the opposite of what the sentence beside it says.
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: verifyText.implicitHeight + 2 * form.ds.space3
                    visible: accounts.verifyOk || accounts.verifyFailed
                    radius: form.ds.radiusMd
                    color: accounts.verifyOk ? form.ds.statusSuccessBg : form.ds.statusInfoBg
                    border.width: form.ds.borderWidth
                    border.color: accounts.verifyOk
                        ? form.ds.mix(form.ds.statusSuccess, form.ds.statusSuccessBg, 0.3)
                        : form.ds.mix(form.ds.statusInfo, form.ds.statusInfoBg, 0.3)

                    Text {
                        id: verifyText

                        anchors.fill: parent
                        anchors.margins: form.ds.space3
                        text: accounts.verifyMessage
                        color: form.ds.textBody
                        wrapMode: Text.WordWrap
                        font.family: form.ds.fontSans
                        font.pixelSize: form.ds.textSm
                    }
                }
            }
        }

        // ---- right: the way back in ------------------------------------------------------
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredWidth: 1
            Layout.alignment: Qt.AlignTop
            implicitHeight: adminBody.implicitHeight + 2 * form.ds.space6
            radius: form.ds.radiusLg
            color: form.ds.surfacePage
            border.width: form.ds.borderWidth
            border.color: form.ds.borderSubtle

            ColumnLayout {
                id: adminBody

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: form.ds.space6
                spacing: form.ds.space5 - 2

                Text {
                    Layout.fillWidth: true
                    text: accounts.adminHeading.toUpperCase()
                    color: form.ds.textMuted
                    elide: Text.ElideRight
                    font.family: form.ds.fontMono
                    font.pixelSize: 11
                    font.letterSpacing: form.ds.tracking(form.ds.trackingCaps, 11)
                }

                Text {
                    Layout.fillWidth: true
                    text: accounts.adminIntroText
                    color: form.ds.textMuted
                    wrapMode: Text.WordWrap
                    font.family: form.ds.fontSans
                    font.pixelSize: form.ds.textSm
                    lineHeight: form.ds.leadingNormal
                    lineHeightMode: Text.ProportionalHeight
                }

                Field {
                    Layout.fillWidth: true
                    ds: form.ds
                    label: accounts.loginNameLabel
                    text: accounts.loginName
                    error: accounts.loginNameMessage
                    mono: true
                    onEdited: function (value) { accounts.loginName = value; }
                }

                // The meter belongs to the field it scores, in the same cell — see LocalForm.
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: form.ds.space2

                    Field {
                        Layout.fillWidth: true
                        ds: form.ds
                        label: accounts.passwordLabel
                        text: accounts.password
                        error: accounts.passwordMessage
                        echoPassword: true
                        onEdited: function (value) { accounts.password = value; }
                    }

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
                    error: accounts.passwordRepeat.length > 0 && !accounts.passwordsMatch
                        ? accounts.passwordsDifferText
                        : ""
                    echoPassword: true
                    onEdited: function (value) { accounts.passwordRepeat = value; }
                }
            }
        }
    }

    // ---- below both columns ---------------------------------------------------------------
    // Advanced is full width rather than inside the domain panel because its labels are the
    // longest on the page and there are three of them: in a half-width panel they would be the
    // thing that decided the split.
    Button {
        id: advancedToggle

        property bool open: false

        ds: form.ds
        variant: "ghost"
        size: "sm"
        label: accounts.advancedLabel
        onClicked: advancedToggle.open = !advancedToggle.open
    }

    GridLayout {
        Layout.fillWidth: true
        visible: advancedToggle.open
        columns: form.twoColumns ? 2 : 1
        columnSpacing: form.ds.space5 - 2
        rowSpacing: form.ds.space5 - 2

        Field {
            Layout.fillWidth: true
            ds: form.ds
            label: accounts.computerOuLabel
            text: accounts.computerOu
            placeholder: "OU=Laptops,DC=corp,DC=example,DC=com"
            mono: true
            onEdited: function (value) { accounts.computerOu = value; }
        }

        Field {
            Layout.fillWidth: true
            ds: form.ds
            label: accounts.adminGroupLabel
            text: accounts.adminGroup
            placeholder: "Domain Admins"
            onEdited: function (value) { accounts.adminGroup = value; }
        }

        Field {
            Layout.fillWidth: true
            ds: form.ds
            label: accounts.computerAccountLabel
            text: accounts.computerName
            placeholder: accounts.computerAccountPlaceholder
            mono: true
            onEdited: function (value) { accounts.computerName = value; }
        }
    }

    // The machine's own name, and it belongs to neither panel: it is the hostname in every mode,
    // it is what the computer account defaults to above, and putting it under one of the two
    // accounts would have implied it was part of that account.
    ComputerNameField {
        Layout.fillWidth: true
        Layout.maximumWidth: form.twoColumns ? (form.width - (form.ds.space5 - 2)) / 2 : form.width
        ds: form.ds
    }
}
