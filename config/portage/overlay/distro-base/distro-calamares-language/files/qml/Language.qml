/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The language page (plan/22 §1).
 *
 * ONE SCREEN, since plan/23. This page used to carry the greeting and the requirements verdict as
 * a second screen behind the window's own Next; they are their own module now, for the reason
 * plan/23 §1 records — a view step with two screens has one sidebar entry, so the installer's
 * first two questions looked like one step and the second one could not be reached from the
 * sidebar at all.
 *
 * THE ROOT ITEM IS A PLAIN Item, for the reason Accounts.qml gives: this is loaded into a
 * QQuickWidget that Calamares parents into its own window, so an ApplicationWindow would be a
 * second window that never appears and a Kirigami page assumes a stack that is not there.
 *
 * qsTr(), never i18n(). There is no KLocalizedContext on this engine and installing one would
 * cost a ki18n dependency for nothing (plan/19 §7.2 measured the ReferenceError).
 *
 * `language` is the LanguageConfig context property.
 *
 * THE PAGE HAS ONE LINE OF TEXT ON IT, AND THAT IS THE DESIGN. A list of nine languages written
 * in those languages explains itself to everybody who can see it; an English sentence above it
 * explains nothing to the people the screen exists for. Even the header word is drawn in the
 * language currently highlighted — `language.headerWord` is tr("Language") re-read on every
 * translator swap — so arrowing down the list is its own label. The greeting is one Next away, in
 * a language the reader picked.
 *
 * WHY THE LIST IS A ListView AND THE ACCOUNTS CHOOSER IS NOT. That page compares three
 * alternatives with one selected, which is what a radio group is for. This one is scanned for a
 * single row out of nine, which is a list — and a ListView is also the only one of the two that
 * gives arrow keys and Home/End for free, on a page some of whose users cannot read the labels on
 * anything else. Selecting is immediate and live: the whole window retranslates as the highlight
 * moves, which is the clearest possible confirmation that the choice took effect.
 */
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Item {
    id: root

    // Calamares' window paints nothing behind this widget, so the page paints its own ground.
    Rectangle {
        anchors.fill: parent
        color: Kirigami.Theme.backgroundColor
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.largeSpacing

        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            Kirigami.Icon {
                source: "preferences-desktop-locale"
                implicitWidth: Kirigami.Units.iconSizes.large
                implicitHeight: Kirigami.Units.iconSizes.large
            }

            Kirigami.Heading {
                Layout.fillWidth: true
                level: 2
                wrapMode: Text.WordWrap
                text: language.headerWord
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            // Nine rows are 396px of a 536px viewport, so nothing scrolls today. The ScrollView
            // is here for the row that gets added anyway: past eleven entries this list needs a
            // scrollbar and probably a filter field, and config/languages.conf says so.
            contentWidth: availableWidth
            clip: true

            ListView {
                id: list

                // CONSTANT, AND IT HAS TO STAY THAT WAY. QQuickItemViewPrivate::connectModel()
                // forces setCurrentIndex( count > 0 ? 0 : -1 ) whenever a model is assigned to a
                // view that is ALREADY complete — so a `languages` property that could be
                // reassigned would put the row-0 bug back without either line below changing.
                model: language.languages

                // ======== the selection, and it crosses this boundary in both directions =======
                //
                // ONE HIGHLIGHT SOURCE. `highlighted: ListView.isCurrentItem` below means the
                // view's currentIndex is what the page draws as selected, so every way of
                // choosing a language has to go through it — including the mouse. A
                // QQC2.ItemDelegate does NOT move its view's currentIndex when clicked, which is
                // why `onClicked` writes to this property and not to C++: the first version wrote
                // straight to `language.currentIndex`, so a click changed the language (the whole
                // window really did retranslate) and left the highlight on whichever row the
                // keyboard had last visited.
                //
                // -1 EXPLICITLY, and it is load order rather than taste.
                // QQuickItemView::componentComplete() runs
                //
                //     if ( currentIndex < 0 && !currentIndexCleared ) updateCurrent( 0 );
                //
                // and setCurrentIndex() assigns `currentIndexCleared = ( index == -1 )` BEFORE its
                // early return on an unchanged value — so writing -1 here is the only thing that
                // stops the view choosing row 0 for itself. Without it the order of events was:
                // the view selects row 0, onCurrentIndexChanged pushes that 0 into C++, and the
                // English that LanguageConfig::setConfigurationMap() had just chosen became
                // whatever language config/languages.conf happens to list first. That is why the
                // installer opened in German.
                currentIndex: -1

                // NEITHER DIRECTION IS A BINDING, and neither can be: ListView assigns
                // currentIndex itself on every arrow key, which would break a
                // `currentIndex: language.currentIndex` binding permanently and leave the C++ side
                // unable to drive the highlight ever again. Two imperative handlers instead, and
                // they cannot ring: LanguageConfig::setCurrentIndex() returns without a signal
                // when the value has not changed.
                Component.onCompleted: list.currentIndex = language.currentIndex
                onCurrentIndexChanged: language.currentIndex = list.currentIndex

                Connections {
                    target: language
                    // C++ -> QML, because C++ is allowed to REFUSE. setCurrentIndex() drops an
                    // index the model does not have, and without this handler the view would go
                    // on showing a row the installer is not going to install — the two sides
                    // disagreeing with nothing on screen to say so. This puts the view back onto
                    // whatever C++ actually accepted.
                    function onCurrentIndexChanged() {
                        list.currentIndex = language.currentIndex;
                    }
                }

                keyNavigationEnabled: true
                focus: true
                spacing: 0

                delegate: QQC2.ItemDelegate {
                    id: row

                    required property int index
                    required property string label
                    required property string name

                    width: ListView.view ? ListView.view.width : implicitWidth
                    highlighted: ListView.isCurrentItem
                    hoverEnabled: true
                    padding: Kirigami.Units.smallSpacing
                    leftPadding: Kirigami.Units.largeSpacing
                    rightPadding: Kirigami.Units.largeSpacing

                    // The view, not `language.currentIndex` — see the block above.
                    onClicked: list.currentIndex = row.index
                    // The accessible name is the native label and nothing else: a screen reader
                    // set to the current UI language would read the translated second line in the
                    // wrong voice anyway, and the native name is the identifier.
                    Accessible.name: row.label

                    // HAND-BUILT, for the reason plan/21 §1b records: a delegate's background is
                    // a style decision, and Fusion fills it with palette.base — an opaque white
                    // slab per row, over the page's own ground. Transparent unless hovered,
                    // focused or current, under every style on the medium.
                    background: Rectangle {
                        radius: Kirigami.Units.cornerRadius
                        color: row.highlighted
                            ? Qt.alpha(Kirigami.Theme.highlightColor, 0.15)
                            : (row.hovered ? Qt.alpha(Kirigami.Theme.hoverColor, 0.25)
                                           : "transparent")
                        border.width: row.highlighted || row.visualFocus ? 1 : 0
                        border.color: row.visualFocus ? Kirigami.Theme.focusColor
                                                      : Kirigami.Theme.highlightColor

                        // The accent rail. It is the one mark on the row that survives being
                        // rendered in a theme with no colour difference between the states.
                        Rectangle {
                            visible: row.highlighted
                            width: 3
                            radius: width
                            color: Kirigami.Theme.highlightColor
                            anchors {
                                left: parent.left
                                top: parent.top
                                bottom: parent.bottom
                                topMargin: Kirigami.Units.smallSpacing
                                bottomMargin: Kirigami.Units.smallSpacing
                            }
                        }
                    }

                    contentItem: RowLayout {
                        spacing: Kirigami.Units.largeSpacing

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            // The native name, larger than everything else on the row. This is
                            // the string a person is looking for, and it is NEVER translated:
                            // it has to read the same whatever the UI language currently is,
                            // because it is how somebody who landed in the wrong language finds
                            // their way out.
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: row.label
                                font.bold: row.highlighted
                                font.pointSize: Kirigami.Theme.defaultFont.pointSize + 1
                                elide: Text.ElideRight
                            }

                            // The same language's name IN THE LANGUAGE CURRENTLY SELECTED —
                            // "ドイツ語" once 日本語 is chosen. Never a locale code, which is the
                            // whole point of curating config/languages.conf by hand.
                            QQC2.Label {
                                Layout.fillWidth: true
                                text: row.name
                                opacity: 0.7
                                font: Kirigami.Theme.smallFont
                                elide: Text.ElideRight
                            }
                        }

                        Kirigami.Icon {
                            visible: row.highlighted
                            source: "dialog-ok"
                            implicitWidth: Kirigami.Units.iconSizes.small
                            implicitHeight: Kirigami.Units.iconSizes.small
                        }
                    }
                }
            }
        }
    }
}
