/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The summary page (plan/28 §6).
 *
 * THE ROOT ITEM IS A PLAIN Item, for the reason every sibling page gives: this is loaded into a
 * QQuickWidget that Calamares parents into its own window, so an ApplicationWindow would be a
 * second window that never appears and a Kirigami page assumes a stack that is not there.
 *
 * No qsTr() in this file. The builder's lupdate is built without QML support (plan/27 §1), so a
 * qsTr() here would never reach the branding catalogue. Every word is a ReviewConfig property,
 * tr()'d in C++ — and the ROWS are other steps' words, each already translated by the module
 * that owns it.
 *
 * `review` is the ReviewConfig context property.
 *
 * A TABLE, NOT A STACK OF HEADINGS, which is the substantive change from the page this replaces.
 * The stock summary renders each step's prettyDescription() as a heading and a paragraph; what
 * somebody needs on the last screen before a whole-disk erase is every decision they made, on
 * one line each, and the name of the disk in a colour that says what is about to happen to it.
 */
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Item {
    id: root

    // THE PAGE PAINTS THE DESIGN SYSTEM, NOT THE DESKTOP THEME (plan/28). Without this block
    // Kirigami resolves these out of Breeze. There is no Kirigami.Theme.Custom colour set — the
    // ColorSet enum is View/Window/Button/Selection/Tooltip/Complementary/Header — so clearing
    // `inherit` is the switch and the assignments below are the theme.
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

    // The page owns the token object so a handoff to a child can be qualified — see Theme.qml.
    readonly property Theme ds: Theme {}

    Rectangle {
        anchors.fill: parent
        color: ds.surfaceCard
    }

    // THE WHOLE PAGE SCROLLS, AND THE TABLE DOES NOT (plan/30 §4). It used to be the other way
    // round: the page was a fixed ColumnLayout and the table a ScrollView inside it sized by
    // Layout.fillHeight — so on a six-row summary the table was tall enough for five rows and a
    // sliver, and the first decision the page reports sat behind a scrollbar twenty pixels long.
    // That is the exact shape the applications page was asked to lose, for the same reason.
    //
    // The table is as tall as its rows now and the PAGE scrolls if the sum does not fit, which
    // at 1024x640 it does. Same sheet-Item pattern as Accounts.qml and Apps.qml, for the reason
    // their headers give: qqc2-desktop-style's ScrollView binds the four individual padding
    // properties, so an assignment to the grouped `padding` loses to them and the margins have
    // to be the content's.
    QQC2.ScrollView {
        id: scroll

        anchors.fill: parent
        contentWidth: availableWidth
        clip: true

        Item {
            id: sheet

            readonly property int margin: ds.pageMarginV
            readonly property int sideMargin: ds.pageMarginH

            width: scroll.availableWidth
            implicitHeight: column.implicitHeight + 2 * margin

            ColumnLayout {
                id: column

                x: sheet.sideMargin
                y: sheet.margin
                width: Math.min(sheet.width - 2 * sheet.sideMargin, ds.contentMaxWidth)
                spacing: ds.space6
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.maximumWidth: ds.contentMaxWidth
                    spacing: ds.space2

                    Text {
                        Layout.fillWidth: true
                        text: review.pageTitle
                        color: ds.textStrong
                        wrapMode: Text.WordWrap
                        font.family: ds.fontDisplay
                        font.pixelSize: ds.textHeading
                        font.weight: ds.weightBold
                        font.letterSpacing: ds.tracking(ds.trackingTight, ds.textHeading)
                    }

                    Text {
                        Layout.fillWidth: true
                        text: review.pageLede
                        color: ds.textMuted
                        wrapMode: Text.WordWrap
                        font.family: ds.fontSans
                        font.pixelSize: ds.textMd
                        lineHeight: ds.leadingNormal
                        lineHeightMode: Text.ProportionalHeight
                    }
                }


                // ---- the decisions ---------------------------------------------------------
                // One border round the whole table and a hairline between rows, which is the
                // design system's shape for a list of facts: nothing here is a choice and
                // nothing is clickable, so a card per row would be promising an interaction the
                // page does not have.
                Rectangle {
                    Layout.fillWidth: true
                    // AS TALL AS ITS ROWS. No binding loop: contentHeight is the sum of the
                    // delegates' heights, each of which depends on the view's WIDTH — the values
                    // wrap — and width does not depend on this.
                    implicitHeight: rows.contentHeight + 2 * ds.borderWidth
                    radius: ds.radiusLg
                    color: ds.surfaceCard
                    border.width: ds.borderWidth
                    border.color: ds.borderSubtle
                    clip: true

                    ListView {
                        id: rows

                        anchors.fill: parent
                        anchors.margins: ds.borderWidth
                        // NOT INTERACTIVE, because there is nothing to scroll to: the view is
                        // exactly as tall as its content. A flickable that cannot move still
                        // eats a wheel event, which on a page that scrolls as a whole would be a
                        // dead patch in the middle of it.
                        interactive: false
                        model: review.rows
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
                                anchors.leftMargin: ds.space5 - 2
                                anchors.rightMargin: ds.space5 - 2
                                spacing: ds.space5

                                Text {
                                    id: rowLabel

                                    // The step's name, which is what the sidebar calls it — so a row
                                    // and the step it came from are findable from each other.
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
                                    font.family: ds.fontSans
                                    font.pixelSize: ds.textSm
                                    font.weight: ds.weightMedium
                                }
                            }
                        }
                    }
                }

                // ---- and what it costs -------------------------------------------------------------
                // The design system's `danger` Alert, and the only one in the installer that is not
                // reporting a failure: it is reporting what pressing the next button does. The disk is
                // NAMED, because a sentence about "the selected disk" is a sentence nobody has to read.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.maximumWidth: ds.contentMaxWidth
                    implicitHeight: eraseBody.implicitHeight + eraseTitle.implicitHeight
                        + 2 * ds.space4 + ds.space1
                    radius: ds.radiusMd
                    color: ds.statusDangerBg
                    border.width: ds.borderWidth
                    border.color: ds.mix(ds.statusDanger, ds.statusDangerBg, 0.3)

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: ds.space4
                        spacing: ds.space1

                        Text {
                            id: eraseTitle

                            Layout.fillWidth: true
                            text: review.eraseTitle
                            color: ds.textStrong
                            wrapMode: Text.WordWrap
                            font.family: ds.fontSans
                            font.pixelSize: ds.textSm
                            font.weight: ds.weightSemibold
                        }

                        Text {
                            id: eraseBody

                            Layout.fillWidth: true
                            text: review.eraseBody
                            color: ds.textBody
                            wrapMode: Text.WordWrap
                            font.family: ds.fontSans
                            font.pixelSize: ds.textSm
                            lineHeight: ds.leadingNormal
                            lineHeightMode: Text.ProportionalHeight
                        }
                    }
                }
            }
        }
    }
}
