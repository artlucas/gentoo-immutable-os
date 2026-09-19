/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The location page (plan/28 §6).
 *
 * THE ROOT ITEM IS A PLAIN Item, for the reason every sibling page gives.
 *
 * No qsTr() in this file. The builder's lupdate is built without QML support (plan/27 §1), so
 * every word is a LocationConfig property, tr()'d in C++ — and the region and zone NAMES are
 * Calamares' own translations, read off the models it exports.
 *
 * `location` is the LocationConfig context property.
 *
 * WHAT IS NOT ON THIS PAGE and why — the Formats, Measurement and 24-hour controls the design
 * hand-off draws — is written out in LocationConfig.h. Short version: two of them would offer
 * locales the image did not compile, and the third is a setting nothing in this pipeline writes
 * to the installed system. Automatic time was in that list until plan/29 built the wiring; it is
 * the checkbox in the clock card below, and checking it runs timedatectl on this machine.
 */
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Item {
    id: root

    // THE PAGE PAINTS THE DESIGN SYSTEM, NOT THE DESKTOP THEME (plan/28). There is no
    // Kirigami.Theme.Custom colour set, so clearing `inherit` is the switch.
    Kirigami.Theme.inherit: false
    Kirigami.Theme.backgroundColor: ds.surfaceCard
    Kirigami.Theme.alternateBackgroundColor: ds.surfacePage
    Kirigami.Theme.textColor: ds.textBody
    Kirigami.Theme.disabledTextColor: ds.textSubtle
    Kirigami.Theme.highlightColor: ds.accent
    Kirigami.Theme.highlightedTextColor: ds.accentOn
    Kirigami.Theme.hoverColor: ds.accentSoft
    Kirigami.Theme.focusColor: ds.accent
    Kirigami.Theme.activeTextColor: ds.accentStrong
    Kirigami.Theme.linkColor: ds.textLink
    Kirigami.Theme.positiveTextColor: ds.statusSuccess
    Kirigami.Theme.neutralTextColor: ds.statusWarning
    Kirigami.Theme.negativeTextColor: ds.statusDanger

    readonly property Theme ds: Theme {}

    Rectangle {
        anchors.fill: parent
        color: ds.surfaceCard
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: ds.space8 + ds.space1
        anchors.bottomMargin: ds.space8 + ds.space1
        anchors.leftMargin: ds.space10 + ds.space1
        anchors.rightMargin: ds.space10 + ds.space1
        spacing: ds.space6 + 2

        ColumnLayout {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            spacing: ds.space2

            Text {
                Layout.fillWidth: true
                text: location.pageTitle
                color: ds.textStrong
                wrapMode: Text.WordWrap
                font.family: ds.fontDisplay
                font.pixelSize: ds.textHeading
                font.weight: ds.weightBold
                font.letterSpacing: ds.tracking(ds.trackingTight, ds.textHeading)
            }

            Text {
                Layout.fillWidth: true
                text: location.pageLede
                color: ds.textMuted
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textMd
                lineHeight: ds.leadingNormal
                lineHeightMode: Text.ProportionalHeight
            }
        }

        // ---- the clock ---------------------------------------------------------------------
        // THE ONE CONTROL ON THIS INSTALLER WHOSE EFFECT CAN BE CHECKED BY LOOKING AT IT. Region
        // and zone are two dropdowns of names; this is what choosing them MEANS, in the chosen
        // zone, ticking. It is set in mono at 44px because it is a reading, not a heading.
        Rectangle {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            implicitHeight: clockCard.implicitHeight + 2 * (ds.space5 + 2)
            radius: ds.radiusLg
            color: ds.surfacePage
            border.width: ds.borderWidth
            border.color: ds.borderSubtle

            // THE CLOCK AND HOW IT IS SET ARE ONE CARD (plan/29). The reading, the control that
            // decides where the reading comes from, and the line that says whether that worked
            // are three parts of one answer, and a person checking the time is checking all
            // three. Splitting them into separate panels would put the evidence a panel away
            // from the claim.
            ColumnLayout {
                id: clockCard

                anchors.fill: parent
                anchors.margins: ds.space5 + 2
                spacing: ds.space5 - 2

                RowLayout {
                    id: clockRow

                    Layout.fillWidth: true
                    spacing: ds.space6

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Text {
                            text: location.clockTime
                            color: ds.textStrong
                            font.family: ds.fontMono
                            font.pixelSize: 44
                            font.weight: ds.weightMedium
                        }

                        Text {
                            Layout.fillWidth: true
                            text: location.clockDate
                            color: ds.textMuted
                            elide: Text.ElideRight
                            font.family: ds.fontSans
                            font.pixelSize: ds.textSm
                        }
                    }

                    ColumnLayout {
                        Layout.alignment: Qt.AlignTop
                        spacing: ds.space2

                        // The design system's `accent` Badge, in mono because a zone id is an
                        // identifier.
                        Rectangle {
                            Layout.alignment: Qt.AlignRight
                            implicitWidth: zoneBadge.implicitWidth + 2 * ds.space2
                            implicitHeight: 20
                            radius: ds.radiusSm
                            color: ds.accentTint

                            Text {
                                id: zoneBadge

                                anchors.centerIn: parent
                                text: location.zoneId
                                color: ds.accentStrong
                                font.family: ds.fontMono
                                font.pixelSize: ds.textXs
                                font.weight: ds.weightMedium
                            }
                        }

                        Text {
                            Layout.alignment: Qt.AlignRight
                            text: location.offsetText
                            color: ds.textMuted
                            font.family: ds.fontMono
                            font.pixelSize: ds.textXs
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: ds.borderWidth
                    color: ds.divider
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: ds.space4

                    // A CHECKBOX WITH indicator: null, the shape Apps.qml's application tiles
                    // use: qqc2-desktop-style draws Breeze's box — its size, its radius, its
                    // tick and its focus ring — whatever Kirigami.Theme says about colour, so
                    // the mark is drawn in the contentItem and the control keeps only the parts
                    // that are Qt's to own (keyboard, accessibility, the toggle itself).
                    QQC2.CheckBox {
                        id: ntpBox

                        Layout.fillWidth: true
                        padding: 0
                        spacing: 0

                        checked: location.networkTime
                        // NOT JUST A SETTING — the write runs timedatectl on this machine and
                        // starts the watch, so the box is the action and C++ is where it happens.
                        onToggled: location.networkTime = ntpBox.checked

                        Accessible.name: location.networkTimeLabel
                        Accessible.description: location.networkTimeHint

                        // C++ IS THE SOURCE OF TRUTH, and the binding above stops being one the
                        // first time somebody clicks: QQC2 assigns `checked` itself on a toggle.
                        // This is what puts back whatever C++ accepted — the same arrangement the
                        // two pickers above use, for the same reason.
                        Connections {
                            target: location
                            function onNetworkTimeChanged() {
                                ntpBox.checked = location.networkTime;
                            }
                        }

                        HoverHandler {
                            id: ntpHover
                            cursorShape: Qt.PointingHandCursor
                        }

                        indicator: null

                        contentItem: RowLayout {
                            spacing: ds.space3

                            // The design system's Checkbox mark: a 20px square with a 2px ring,
                            // filled with the accent and ticked when on.
                            Rectangle {
                                Layout.alignment: Qt.AlignTop
                                implicitWidth: 20
                                implicitHeight: 20
                                radius: ds.radiusSm
                                color: ntpBox.checked ? ds.accent : "transparent"
                                border.width: ds.borderWidthStrong
                                border.color: ntpBox.checked
                                    ? ds.accent
                                    : (ntpBox.visualFocus || ntpHover.hovered
                                        ? ds.accent
                                        : ds.borderStrong)

                                Behavior on color {
                                    ColorAnimation { duration: ds.durationBase }
                                }

                                Text {
                                    anchors.centerIn: parent
                                    visible: ntpBox.checked
                                    text: "✓"
                                    color: ds.accentOn
                                    font.family: ds.fontSans
                                    font.pixelSize: ds.textXs
                                    font.weight: ds.weightBold
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 3

                                Text {
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 0
                                    text: location.networkTimeLabel
                                    color: ds.textStrong
                                    wrapMode: Text.WordWrap
                                    font.family: ds.fontSans
                                    font.pixelSize: ds.textSm
                                    font.weight: ds.weightMedium
                                }

                                Text {
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 0
                                    text: location.networkTimeHint
                                    color: ds.textMuted
                                    wrapMode: Text.WordWrap
                                    font.family: ds.fontSans
                                    font.pixelSize: ds.textXs
                                }
                            }
                        }
                    }

                    // DISABLED WHILE THE NETWORK OWNS THE CLOCK, rather than left to fail and
                    // explain: systemd refuses `timedatectl set-time` outright when NTP is on.
                    Button {
                        Layout.alignment: Qt.AlignVCenter
                        ds: root.ds
                        variant: "secondary"
                        size: "sm"
                        label: location.setTimeLabel
                        enabled: location.canSetTime
                        onClicked: {
                            location.clearSetTimeError();
                            dateField.text = location.editDate();
                            timeField.text = location.editTime();
                            setTimeDialog.open();
                        }
                    }
                }

                // WHAT ACTUALLY HAPPENED, which is the whole reason the box does work rather
                // than just recording a preference. "Checking the time server…" becomes either a
                // server's name or the admission that none answered — and the second one is the
                // message worth having, because a clock that is quietly wrong is how a TLS
                // handshake fails three screens later with an error about certificates.
                Text {
                    Layout.fillWidth: true
                    text: location.syncStatus
                    color: location.syncState === "ok"
                        ? ds.statusSuccess
                        : (location.syncState === "failed" || location.syncState === "unavailable"
                            ? ds.statusDanger
                            : ds.textMuted)
                    wrapMode: Text.WordWrap
                    font.family: ds.fontSans
                    font.pixelSize: ds.textXs
                }
            }
        }

        // ---- the two questions --------------------------------------------------------------
        GridLayout {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            columns: 2
            columnSpacing: ds.space5 - 2
            rowSpacing: ds.space5 - 2

            // A SELECT, HAND-DRAWN, for the reason every control on these pages is: the desktop
            // style paints Breeze's combo box whatever Kirigami.Theme says about colour. This is
            // the design system's — a 40px field with a chevron — wrapped round a real
            // QQC2.ComboBox so the popup, the keyboard and the accessibility are Qt's.
            component Picker: ColumnLayout {
                id: picker

                // `ds` AND THE GROUP ARE PASSED IN, NOT REACHED FOR. An inline component is its
                // own component: an unqualified name inside one resolves through the parent
                // CHAIN, which qmllint reports as "a member of a parent element" and which
                // `pragma ComponentBehavior: Bound` exists to discourage. Handing them in as
                // required properties makes the dependency a declaration instead of a lookup —
                // and a lookup that silently returns undefined is a control drawn in no colour
                // at all, which is this whole plan's failure mode.
                required property Theme ds
                required property string label
                required property var model
                required property string value

                signal picked(string key)

                Layout.fillWidth: true
                spacing: picker.ds.space2

                Text {
                    Layout.fillWidth: true
                    text: picker.label
                    color: picker.ds.textStrong
                    elide: Text.ElideRight
                    font.family: picker.ds.fontSans
                    font.pixelSize: picker.ds.textSm
                    font.weight: picker.ds.weightMedium
                }

                QQC2.ComboBox {
                    id: box

                    Layout.fillWidth: true
                    model: picker.model
                    textRole: "name"
                    valueRole: "key"

                    // NOT A BINDING ON currentIndex, for the reason every selection on these
                    // pages gives: a ComboBox assigns its own currentIndex when the user picks,
                    // which breaks one permanently. C++ is the source of truth, this pushes into
                    // it, and the Connections below put back whatever C++ accepted.
                    onActivated: picker.picked(box.valueAt(box.currentIndex))

                    function syncFromConfig() {
                        const want = box.indexOfValue(picker.value);
                        if (want >= 0 && want !== box.currentIndex) {
                            box.currentIndex = want;
                        }
                    }

                    Component.onCompleted: box.syncFromConfig()
                    onModelChanged: box.syncFromConfig()

                    Connections {
                        target: location
                        function onLocationChanged() {
                            box.syncFromConfig();
                        }
                    }

                    background: Rectangle {
                        implicitHeight: picker.ds.controlHeightMd
                        radius: picker.ds.radiusMd
                        color: picker.ds.surfaceCard
                        border.width: picker.ds.borderWidth
                        border.color: box.activeFocus || box.popup.visible
                            ? picker.ds.accent
                            : (box.hovered ? picker.ds.borderStrong : picker.ds.borderDefault)

                        Behavior on border.color {
                            ColorAnimation { duration: picker.ds.durationBase }
                        }
                    }

                    contentItem: Text {
                        leftPadding: picker.ds.space3
                        rightPadding: picker.ds.space8
                        verticalAlignment: Text.AlignVCenter
                        text: box.displayText
                        color: picker.ds.textStrong
                        elide: Text.ElideRight
                        font.family: picker.ds.fontSans
                        font.pixelSize: picker.ds.textBase
                    }

                    indicator: Canvas {
                        x: box.width - width - picker.ds.space3
                        y: (box.height - height) / 2
                        width: 16
                        height: 16
                        // The design system's chevron, drawn rather than an icon name: a
                        // Kirigami.Icon would resolve Breeze's, in Breeze's colour.
                        onPaint: {
                            const ctx = getContext("2d");
                            ctx.reset();
                            ctx.strokeStyle = picker.ds.textMuted;
                            ctx.lineWidth = 2;
                            ctx.lineCap = "round";
                            ctx.lineJoin = "round";
                            ctx.beginPath();
                            ctx.moveTo(4, 6);
                            ctx.lineTo(8, 10);
                            ctx.lineTo(12, 6);
                            ctx.stroke();
                        }
                    }
                }
            }

            Picker {
                ds: root.ds
                label: location.regionLabel
                model: location.regions
                value: location.region
                onPicked: function (key) { location.region = key; }
            }

            Picker {
                ds: root.ds
                label: location.zoneLabel
                model: location.zones
                value: location.zone
                onPicked: function (key) { location.zone = key; }
            }
        }

        Item {
            Layout.fillHeight: true
        }
    }

    // ---- the set-time dialog (plan/29) -----------------------------------------------------
    //
    // NOT a Kirigami.PromptDialog, which is what the disk page's erase confirmation uses. That
    // one is drawn by Breeze — its buttons, its title bar, its metrics — and it is the one
    // unbranded surface left in this installer, noted rather than defended. Copying it here
    // would have made two.
    //
    // A QQC2.Popup instead, with everything drawn: the shade is the design system's overlay
    // token, the card is a surface with the system's own radius and border, and the two actions
    // are its Buttons. What QQC2 is kept for is what a hand-rolled overlay gets wrong — modality,
    // Escape, focus capture and restoring focus to whatever had it when this opened.
    QQC2.Popup {
        id: setTimeDialog

        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        width: Math.min(root.width - 2 * ds.space8, 460)
        modal: true
        focus: true
        // NOT CloseOnPressOutside. A half-typed clock correction thrown away by a stray click on
        // the page behind it is a small loss with no undo; Escape and Cancel are both one key or
        // one click away and both say what they do.
        closePolicy: QQC2.Popup.CloseOnEscape
        padding: ds.space6

        QQC2.Overlay.modal: Rectangle {
            color: ds.surfaceOverlay
        }

        background: Rectangle {
            radius: ds.radiusXl
            color: ds.surfaceCard
            border.width: ds.borderWidth
            border.color: ds.borderSubtle
        }

        contentItem: ColumnLayout {
            spacing: ds.space4

            Text {
                Layout.fillWidth: true
                text: location.setTimeTitle
                color: ds.textStrong
                wrapMode: Text.WordWrap
                font.family: ds.fontDisplay
                font.pixelSize: ds.textLg
                font.weight: ds.weightBold
            }

            Text {
                Layout.fillWidth: true
                text: location.setTimeBody
                color: ds.textMuted
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textSm
                lineHeight: ds.leadingNormal
                lineHeightMode: Text.ProportionalHeight
            }

            // TWO COLUMNS THAT DO NOT MOVE. Field carries `Layout.preferredWidth: 0` on both of
            // its Texts for exactly this case (see its header): the error below is one sentence
            // longer than the hint it replaces, and without that a grid column would widen to
            // fit the sentence unwrapped and take the width out of the other field.
            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: ds.space4
                rowSpacing: ds.space4

                Field {
                    id: dateField

                    Layout.fillWidth: true
                    ds: root.ds
                    mono: true
                    label: location.setTimeDateLabel
                    hint: location.setTimeDateHint
                    onEdited: location.clearSetTimeError()
                }

                Field {
                    id: timeField

                    Layout.fillWidth: true
                    ds: root.ds
                    mono: true
                    label: location.setTimeTimeLabel
                    hint: location.setTimeTimeHint
                    onEdited: location.clearSetTimeError()
                }
            }

            // ONE MESSAGE FOR BOTH FIELDS, and it names which one it is about ("The date must be
            // written year-month-day, as in 2026-09-18."). Field's own `error` slot would put the
            // complaint under the field it belongs to, which is better — and would need C++ to
            // decide, before anything is parsed, which of the two a failure will turn out to be.
            // Whichever field is wrong, there is exactly one thing wrong at a time here.
            Text {
                Layout.fillWidth: true
                visible: location.setTimeError.length > 0
                text: location.setTimeError
                color: ds.statusDanger
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textXs
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: ds.space1
                spacing: ds.space3

                Item {
                    Layout.fillWidth: true
                }

                Button {
                    ds: root.ds
                    variant: "ghost"
                    size: "sm"
                    label: location.setTimeCancel
                    onClicked: setTimeDialog.close()
                }

                Button {
                    ds: root.ds
                    variant: "primary"
                    size: "sm"
                    label: location.setTimeConfirm
                    // CLOSED ONLY IF C++ ACCEPTED IT. A dialog that dismissed itself on a
                    // malformed date would leave the clock wrong and the message on a page
                    // nobody is looking at any more.
                    onClicked: {
                        if (location.applySystemTime(dateField.text, timeField.text)) {
                            setTimeDialog.close();
                        }
                    }
                }
            }
        }
    }
}
