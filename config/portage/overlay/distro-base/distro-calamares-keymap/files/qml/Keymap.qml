/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The keyboard page (plan/28 §6).
 *
 * THE ROOT ITEM IS A PLAIN Item, for the reason every sibling page gives.
 *
 * No qsTr() in this file. The builder's lupdate is built without QML support (plan/27 §1), so
 * every word is a LocationConfig property, tr()'d in C++ — and the region and zone NAMES are
 * Calamares' own translations, read off the models it exports.
 *
 * `keymap` is the KeymapConfig context property.
 *
 * THE PREVIEW IS THE CHECK, and the design hand-off's "type here to test" box is deliberately not
 * here. This page does not change the LIVE session's layout — the medium runs kwin_wayland with
 * --locale1, so switching it would mean talking to systemd-localed over polkit and re-keying the
 * machine the user is standing at — so a box to type in would be testing the layout they already
 * have, and agreeing with it no matter what the dropdowns said. The three rows below are
 * libxkbcommon's answer for the SELECTED layout, which is the question the page is actually
 * asking. KeymapConfig.h has the long version.
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
                text: keymap.pageTitle
                color: ds.textStrong
                wrapMode: Text.WordWrap
                font.family: ds.fontDisplay
                font.pixelSize: ds.textHeading
                font.weight: ds.weightBold
                font.letterSpacing: ds.tracking(ds.trackingTight, ds.textHeading)
            }

            Text {
                Layout.fillWidth: true
                text: keymap.pageLede
                color: ds.textMuted
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textMd
                lineHeight: ds.leadingNormal
                lineHeightMode: Text.ProportionalHeight
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
                        target: keymap
                        function onSelectionChanged() {
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

                        // The installer's one focus ring, at the offset every other control
                        // draws it (plan/30 §1). The border already moves to the accent on
                        // focus — but it moves to the accent on an OPEN POPUP too, and it is
                        // the same accent the field shows while merely hovered on some pages,
                        // so the border alone cannot say "the keyboard is here".
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -3
                            visible: box.activeFocus
                            radius: picker.ds.radiusMd + 3
                            color: "transparent"
                            border.width: 3
                            border.color: picker.ds.mix(picker.ds.accent,
                                                        picker.ds.surfaceCard, 0.4)
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
                label: keymap.layoutLabel
                model: keymap.layouts
                value: keymap.layout
                enabled: keymap.haveLayouts
                onPicked: function (key) { keymap.layout = key; }
            }

            Picker {
                ds: root.ds
                label: keymap.variantLabel
                model: keymap.variants
                value: keymap.variant
                enabled: keymap.haveLayouts
                onPicked: function (key) { keymap.variant = key; }
            }
        }

        // ---- what those keys will type ------------------------------------------------------
        // Three rows of ten, from libxkbcommon — see KeymapConfig.h. The keys are drawn as the
        // design system's small bordered tiles rather than as a picture of a keyboard: this is a
        // reading of what the selection means, not an illustration of hardware, and a drawn
        // keyboard invites a comparison with the one under the reader's hands that the ten keys
        // per row cannot honour.
        Rectangle {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            implicitHeight: previewBody.implicitHeight + 2 * ds.space5
            visible: keymap.haveLayouts
            radius: ds.radiusLg
            color: ds.surfacePage
            border.width: ds.borderWidth
            border.color: ds.borderSubtle

            ColumnLayout {
                id: previewBody

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: ds.space5
                spacing: ds.space2 + 2

                Text {
                    Layout.fillWidth: true
                    text: keymap.previewLabel.toUpperCase()
                    color: ds.textMuted
                    elide: Text.ElideRight
                    font.family: ds.fontMono
                    font.pixelSize: 11
                    font.letterSpacing: ds.tracking(ds.trackingCaps, 11)
                }

                Repeater {
                    model: keymap.preview

                    RowLayout {
                        id: keyRow

                        required property var modelData

                        Layout.fillWidth: true
                        spacing: 6

                        Repeater {
                            model: keyRow.modelData

                            Rectangle {
                                id: keyCap

                                required property var modelData

                                Layout.fillWidth: true
                                implicitHeight: 36
                                radius: ds.radiusSm
                                color: ds.surfaceCard
                                border.width: ds.borderWidth
                                border.color: ds.borderSubtle

                                Text {
                                    anchors.centerIn: parent
                                    // A key that types nothing under this layout is drawn empty
                                    // rather than skipped: the row is a row of keys, and a gap
                                    // in it would say the keyboard has one fewer.
                                    //
                                    // `keyCap.modelData`, not `parent.modelData`: `parent` is
                                    // whatever this Text happens to be a child of, which is a
                                    // fact about the layout rather than about the data, and the
                                    // day a wrapper is added between them it silently becomes
                                    // undefined — an empty key rather than an error.
                                    text: keyCap.modelData
                                    color: ds.textBody
                                    font.family: ds.fontMono
                                    font.pixelSize: 13
                                }
                            }
                        }
                    }
                }
            }
        }

        // The state with nothing to offer. A medium without x11-misc/xkeyboard-config has no
        // registry to read, and two empty dropdowns with no explanation is the worst version of
        // that. The design system's `info` tone, because the install still finishes.
        Rectangle {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            implicitHeight: noLayouts.implicitHeight + 2 * ds.space3
            visible: !keymap.haveLayouts
            radius: ds.radiusMd
            color: ds.statusInfoBg
            border.width: ds.borderWidth
            border.color: ds.mix(ds.statusInfo, ds.statusInfoBg, 0.3)

            Text {
                id: noLayouts

                anchors.fill: parent
                anchors.margins: ds.space3
                anchors.leftMargin: ds.space4
                anchors.rightMargin: ds.space4
                text: keymap.noLayoutsText
                color: ds.textBody
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textSm
                lineHeight: ds.leadingNormal
                lineHeightMode: Text.ProportionalHeight
            }
        }

        Item {
            Layout.fillHeight: true
        }
    }
}
