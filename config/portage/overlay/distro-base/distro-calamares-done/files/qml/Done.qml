/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The finished page (plan/28 §6).
 *
 * THE ROOT ITEM IS A PLAIN Item, for the reason every sibling page gives: this is loaded into a
 * QQuickWidget that Calamares parents into its own window.
 *
 * No qsTr() in this file. The builder's lupdate is built without QML support (plan/27 §1), so a
 * qsTr() here would never reach the branding catalogue. Every word is a DoneConfig property,
 * tr()'d in C++ — and the ROWS are the preceding steps' own words, each already translated by
 * the module that owns it.
 *
 * `done` is the DoneConfig context property.
 */
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Item {
    id: root

    // THE PAGE PAINTS THE DESIGN SYSTEM, NOT THE DESKTOP THEME (plan/28). There is no
    // Kirigami.Theme.Custom colour set, so clearing `inherit` is the switch and the assignments
    // below are the theme.
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

    // CENTRED, which no other page in this installer is. Every screen before this one is a
    // question with a column of controls under it, and reads from the top left; this one is an
    // answer, and the design system centres it for the same reason a receipt is centred — there
    // is nothing to scan, only something to be told.
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 2 * ds.pageMarginH, 600)
        spacing: ds.space6 + ds.space1

        // The one large positive mark in the installer, and the only place the success tone is
        // used at this size.
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: 72
            implicitHeight: 72
            radius: width / 2
            color: ds.statusSuccessBg

            Canvas {
                anchors.centerIn: parent
                width: 34
                height: 34
                // DRAWN, not an icon name: Kirigami.Icon would resolve "dialog-ok" out of the
                // Breeze icon theme, in Breeze's green, which is the one colour on this page that
                // has to be the design system's.
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    ctx.strokeStyle = ds.statusSuccess;
                    ctx.lineWidth = 2.5 * (width / 24);
                    ctx.lineCap = "round";
                    ctx.lineJoin = "round";
                    ctx.beginPath();
                    ctx.moveTo(4 * width / 24, 12 * height / 24);
                    ctx.lineTo(9 * width / 24, 17 * height / 24);
                    ctx.lineTo(20 * width / 24, 6 * height / 24);
                    ctx.stroke();
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: ds.space2 + 2

            Text {
                Layout.fillWidth: true
                text: done.pageTitle
                color: ds.textStrong
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                font.family: ds.fontDisplay
                font.pixelSize: ds.textHeading
                font.weight: ds.weightBold
                font.letterSpacing: ds.tracking(ds.trackingTight, ds.textHeading)
            }

            Text {
                Layout.fillWidth: true
                text: done.pageLede
                color: ds.textMuted
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textMd
                lineHeight: ds.leadingNormal
                lineHeightMode: Text.ProportionalHeight
            }
        }

        // ---- what was installed --------------------------------------------------------
        // The same rows the summary page showed before the erase, in the same words — see
        // DoneConfig.h. Left-aligned inside a centred page, because a table of label/value pairs
        // that is centred is a table nobody can read down.
        Rectangle {
            Layout.fillWidth: true
            Layout.maximumHeight: 260
            implicitHeight: rows.contentHeight + 2
            visible: rows.count > 0
            radius: ds.radiusLg
            color: ds.surfaceCard
            border.width: ds.borderWidth
            border.color: ds.borderSubtle
            clip: true

            QQC2.ScrollView {
                anchors.fill: parent
                contentWidth: availableWidth
                clip: true

                ListView {
                    id: rows

                    model: done.rows
                    currentIndex: -1
                    spacing: 0

                    delegate: Item {
                        id: row

                        required property string label
                        required property string value

                        width: rows.width
                        implicitHeight: Math.max(rowLabel.implicitHeight, rowValue.implicitHeight)
                            + 2 * ds.space3

                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 1
                            visible: row.y + row.height < rows.contentHeight
                            color: ds.divider
                        }

                        RowLayout {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: ds.space4
                            anchors.rightMargin: ds.space4
                            spacing: ds.space4

                            Text {
                                id: rowLabel

                                text: row.label
                                color: ds.textMuted
                                font.family: ds.fontSans
                                font.pixelSize: ds.textSm
                            }

                            Text {
                                id: rowValue

                                Layout.fillWidth: true
                                text: row.value
                                color: ds.textStrong
                                horizontalAlignment: Text.AlignRight
                                wrapMode: Text.WordWrap
                                font.family: ds.fontMono
                                font.pixelSize: ds.textXs
                            }
                        }
                    }
                }
            }
        }

        // ---- and the one thing left to decide -------------------------------------------
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
            visible: done.restartOffered
            spacing: ds.space2

            // THE SHARED CHECK BOX (plan/30 §1). It was drawn here by hand and drawn again,
            // identically, in LocalForm.qml — and neither drawing could be reached or operated
            // from the keyboard, because a RowLayout with a TapHandler is not a control. The
            // shared one carries the tab stop, the focus ring and Space/Return.
            //
            // `checked` STAYS A BINDING. The shared control never assigns its own — it emits and
            // waits to be told — so this re-reads on restartWantedChanged with no handler.
            CheckBox {
                Layout.alignment: Qt.AlignHCenter
                ds: root.ds
                label: done.restartLabel
                checked: done.restartWanted
                onToggled: function (value) { done.restartWanted = value; }
            }

            // Only while the box is ticked: a medium reminder on a page whose machine is not
            // about to restart is advice about something that is not going to happen.
            Text {
                Layout.fillWidth: true
                visible: done.restartWanted
                text: done.mediumReminder
                color: ds.textMuted
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textXs
            }
        }
    }
}
