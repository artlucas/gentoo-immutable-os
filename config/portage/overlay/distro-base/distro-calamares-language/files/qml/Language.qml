/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The language page (plan/22 §1, repainted in plan/28).
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
 * No qsTr() in this file. The builder's lupdate is built without QML support (plan/27 §1), so a
 * qsTr() here would never reach the branding catalogue and would render English in every
 * language. Every word on this page is a LanguageConfig property, tr()'d in C++.
 *
 * `language` is the LanguageConfig context property.
 *
 * ---------------------------------------------------------------------------------------------
 * THE PAGE USED TO HAVE ONE LINE OF TEXT ON IT, AND THAT WAS THE DESIGN. The argument was good:
 * a list of nine languages written in those languages explains itself to everybody who can see
 * it, and an English sentence above it explains nothing to the people the screen exists for. Even
 * the header word is drawn in the language currently highlighted.
 *
 * plan/28 overrode it, deliberately, and this is the record of that. The installer now paints one
 * design from the first screen to the last, and every other page opens with a heading and a lede;
 * a first page that opened with a bare list read as a page that had not finished loading. What
 * survives of the old argument is the part that could be kept: `pageTitle` and `pageLede` are
 * retranslated properties, so they are in the newly chosen language the instant the highlight
 * moves — the same live confirmation the header word always gave.
 *
 * THE SECOND LINE IS NOW THE LOCALE CODE, and that is the other half of the override. It used to
 * be the same language's name in the language currently selected — "ドイツ語" once 日本語 is
 * chosen — on the argument that a locale code is not for humans. It is a code, and it is also the
 * one string on the row that never moves under the reader while everything else on the window
 * retranslates around it. `localeShort`, so the nine identical ".UTF-8" suffixes are not spending
 * width the native name could have.
 *
 * WHY THIS IS A GridView AND NOT A GRID OF Repeater CELLS. The design is two columns; the
 * requirement is arrow keys. A GridView is a view, so it keeps currentIndex, 2-D key navigation
 * and Home/End for free — on a page some of whose users cannot read the labels on anything else.
 * A GridLayout + Repeater would have drawn the same thing and thrown that away.
 */
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami

Item {
    id: root

    // THE PAGE PAINTS THE DESIGN SYSTEM, NOT THE DESKTOP THEME (plan/28). Without this block the
    // page is whatever Plasma ds the live session happens to be running, which is the mismatch
    // the whole plan is about. It matters for the controls this page does not draw itself — the
    // scroll bar, the focus ring; everything it does draw reads `ds` directly.
    //
    // `inherit: false` AND NOTHING ELSE IS THE SWITCH. There is no Kirigami.Theme.Custom colour
    // set — the ColorSet enum is View/Window/Button/Selection/Tooltip/Complementary/Header — and
    // naming one would have evaluated to undefined and been assigned silently, which is this
    // whole plan's failure mode wearing a different hat. Clearing `inherit` is what stops
    // PlatformTheme resolving from Breeze; the assignments below are then the ds.
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

    // The page OWNS the token object rather than merely holding an id for it, and that
    // is what makes `ds: root.ds` below say what it means. Passed down as `ds: ds` it
    // would resolve the right-hand side in the CHILD's scope, where the child's own `ds`
    // property shadows this one — a binding loop, an undefined theme, and a page drawn
    // in whatever a null token object evaluates to.
    readonly property Theme ds: Theme {}

    // Calamares' window paints nothing behind this widget, so the page paints its own ground.
    Rectangle {
        anchors.fill: parent
        color: ds.surfaceCard
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: ds.space8 + ds.space1      // 36, the mockup's content padding
        anchors.bottomMargin: ds.space8 + ds.space1
        anchors.leftMargin: ds.space10 + ds.space1    // 44
        anchors.rightMargin: ds.space10 + ds.space1
        spacing: ds.space6 + 2                           // 26

        ColumnLayout {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            spacing: ds.space2

            Text {
                Layout.fillWidth: true
                text: language.pageTitle
                color: ds.textStrong
                wrapMode: Text.WordWrap
                font.family: ds.fontDisplay
                font.pixelSize: ds.textHeading
                font.weight: ds.weightBold
                font.letterSpacing: ds.tracking(ds.trackingTight, ds.textHeading)
            }

            Text {
                Layout.fillWidth: true
                text: language.pageLede
                color: ds.textMuted
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textMd
                lineHeight: ds.leadingNormal
                lineHeightMode: Text.ProportionalHeight
            }
        }

        GridView {
            id: grid

            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.maximumWidth: ds.contentMaxWidth
            clip: true

            // Two columns, with the mockup's 8px gutter taken out of the cell and given back as a
            // margin inside it — GridView has no spacing property, so the gap has to live in the
            // delegate or it does not exist.
            readonly property int columns: 2
            cellWidth: Math.floor(grid.width / grid.columns)
            cellHeight: 58 + ds.space2

            // CONSTANT, AND IT HAS TO STAY THAT WAY. QQuickItemViewPrivate::connectModel()
            // forces setCurrentIndex( count > 0 ? 0 : -1 ) whenever a model is assigned to a
            // view that is ALREADY complete — so a `languages` property that could be
            // reassigned would put the row-0 bug back without either line below changing.
            model: language.languages

            // ======== the selection, and it crosses this boundary in both directions =======
            //
            // ONE HIGHLIGHT SOURCE. `highlighted: GridView.isCurrentItem` below means the
            // view's currentIndex is what the page draws as selected, so every way of
            // choosing a language has to go through it — including the mouse. A click therefore
            // writes to this property and not to C++: the first version wrote straight to
            // `language.currentIndex`, so a click changed the language (the whole window really
            // did retranslate) and left the highlight on whichever row the keyboard had last
            // visited.
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

            // NEITHER DIRECTION IS A BINDING, and neither can be: the view assigns currentIndex
            // itself on every arrow key, which would break a `currentIndex: language.currentIndex`
            // binding permanently and leave the C++ side unable to drive the highlight ever
            // again. Two imperative handlers instead, and they cannot ring:
            // LanguageConfig::setCurrentIndex() returns without a signal when the value has not
            // changed.
            Component.onCompleted: grid.currentIndex = language.currentIndex
            onCurrentIndexChanged: language.currentIndex = grid.currentIndex

            Connections {
                target: language
                // C++ -> QML, because C++ is allowed to REFUSE. setCurrentIndex() drops an
                // index the model does not have, and without this handler the view would go
                // on showing a row the installer is not going to install — the two sides
                // disagreeing with nothing on screen to say so. This puts the view back onto
                // whatever C++ actually accepted.
                function onCurrentIndexChanged() {
                    grid.currentIndex = language.currentIndex;
                }
            }

            keyNavigationEnabled: true
            focus: true

            // THE VIEW IS THE TAB STOP, NOT THE CELLS (plan/30 §1). A cell is a plain Item with
            // a TapHandler on the card inside it, so nothing here ever held focus and Tab
            // skipped the only control on the page. Tab lands on the VIEW; the arrow keys move
            // within it, which they already did; the ring below is drawn on the current cell
            // while the view has focus.
            activeFocusOnTab: true

            delegate: Item {
                id: cell

                required property int index
                required property string label
                required property string localeShort

                readonly property bool current: GridView.isCurrentItem
                // Where the keyboard is, which on a view whose cells cannot hold focus is the
                // current cell AND a view that has focus — not a property of the cell alone.
                readonly property bool keyboardFocus: grid.activeFocus && cell.current

                width: grid.cellWidth
                height: grid.cellHeight

                Rectangle {
                    id: card

                    anchors.fill: parent
                    anchors.rightMargin: ds.space2
                    anchors.bottomMargin: ds.space2
                    radius: ds.radiusMd
                    // Selected: the accent wash behind an accent border, which is how every
                    // chooser in this installer says "this one" (disk rows, account modes,
                    // application sets). Hover lifts the border only — the design system's
                    // hover is a border change, never a fill.
                    color: cell.current ? ds.accentWash : ds.surfaceCard
                    border.width: ds.borderWidth
                    border.color: cell.current
                        ? ds.accent
                        : (hover.hovered ? ds.borderStrong : ds.borderSubtle)

                    Behavior on border.color {
                        ColorAnimation { duration: ds.durationBase }
                    }

                    // The installer's one focus ring, at the offset every other control draws
                    // it. A border colour alone could not carry this state: the current cell is
                    // ALREADY accent-bordered because it is selected, which is exactly the cell
                    // a keyboard user is standing on.
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -3
                        visible: cell.keyboardFocus
                        radius: ds.radiusMd + 3
                        color: "transparent"
                        border.width: 3
                        border.color: ds.mix(ds.accent, ds.surfaceCard, 0.4)
                    }

                    HoverHandler { id: hover }
                    TapHandler {
                        // The view, not `language.currentIndex` — see the block above.
                        onTapped: grid.currentIndex = cell.index
                    }

                    // The accessible name is the native label and nothing else: a screen reader
                    // set to the current UI language would read a translated second line in the
                    // wrong voice anyway, and the native name is the identifier.
                    Accessible.role: Accessible.RadioButton
                    Accessible.name: cell.label
                    Accessible.checked: cell.current

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: ds.space3 + 2     // 14
                        anchors.rightMargin: ds.space3 + 2
                        anchors.topMargin: ds.space3
                        anchors.bottomMargin: ds.space3
                        spacing: ds.space3

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 2

                            // The native name. NEVER translated: it has to read the same whatever
                            // the UI language currently is, because it is how somebody who landed
                            // in the wrong language finds their way out.
                            Text {
                                Layout.fillWidth: true
                                text: cell.label
                                color: ds.textStrong
                                elide: Text.ElideRight
                                font.family: ds.fontSans
                                font.pixelSize: ds.textSm
                                font.weight: ds.weightMedium
                            }

                            Text {
                                Layout.fillWidth: true
                                text: cell.localeShort
                                color: ds.textMuted
                                elide: Text.ElideRight
                                font.family: ds.fontMono
                                font.pixelSize: 11
                            }
                        }

                        Text {
                            text: "✓"
                            visible: cell.current
                            color: ds.accent
                            font.family: ds.fontSans
                            font.pixelSize: ds.textSm
                        }
                    }
                }
            }
        }
    }
}
