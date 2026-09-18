/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The applications page (plan/25, repainted in plan/28).
 *
 * THE ROOT ITEM IS A PLAIN Item, for the reason Disk.qml gives: this is loaded into a QQuickWidget
 * that Calamares parents into its own window, so a Kirigami ApplicationWindow would be a second
 * window that never appears and a Kirigami page assumes a page stack that is not there.
 *
 * `apps` is the AppsConfig context property. THE MODE IS C++'s, the disk page's rule: the three
 * cards are drawn from apps.mode and push their clicks into it, because two sources of truth for
 * one choice is how a summary page comes to say "Typical application set" about an install that
 * shipped none. The custom list's boxes bind off apps.selectedIds the same way, per box.
 *
 * NO qsTr() ANYWHERE IN THIS FILE, and that is not a preference: the builder's lupdate is built
 * without QML support, so a qsTr() here would never reach the branding catalogue and would render
 * English in all nine languages the language page offers. Every word this page shows is a
 * tr()'d property on AppsConfig — see the note in AppsConfig.h.
 *
 * ONE SCREEN, THREE CHOICES AND A LIST. Offline is not an error state here — it is the one state
 * that changes what the page can ask, so it disables the two choices that need a connection and
 * lets C++ force the third, and the note that replaces them says what to do later rather than
 * what went wrong.
 *
 * WHAT plan/28 CHANGED, AND WHAT IT DELIBERATELY DID NOT. The three stacked rows are a three-up
 * card grid and the app list is a two-column grid of tiles, painted from Theme.qml. The controls
 * underneath are the same QQC2.RadioButton and QQC2.CheckBox they always were — with the card as
 * `background`, the drawn mark as `indicator` and the words as `contentItem`, so the WHOLE card
 * is the control. That is plan/27 §7's finding taken one step further: the label beside a bare
 * radio needed a MouseArea to become clickable, and a label INSIDE the control needs nothing,
 * keeps the keyboard, keeps the button group and keeps the accessibility role.
 *
 * The one thing the design system's page has that this one does not is a per-application download
 * size and a running total. AppsConfig does not know them — Flathub is not queried until the
 * `appsetup` job runs — and a number invented here would be a promise the page cannot keep.
 */
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Item {
    id: root

    // THE PAGE PAINTS THE DESIGN SYSTEM, NOT THE DESKTOP THEME (plan/28). Without this block
    // Kirigami resolves these out of Breeze and the page is whichever Plasma ds the live
    // session happens to run. It matters for the controls this page does not draw itself — the
    // scroll bar above all; the rest reads `ds` directly.
    //
    // `inherit: false` AND NOTHING ELSE IS THE SWITCH. There is no Kirigami.Theme.Custom colour
    // set — the ColorSet enum is View/Window/Button/Selection/Tooltip/Complementary/Header — and
    // naming one would have evaluated to undefined and been assigned silently, which is this
    // whole plan's failure mode wearing a different hat.
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

    // The three answers are exclusive; RadioButtons in different cells of a GridLayout are not
    // siblings, so the group is named rather than left to parent-based auto-exclusivity.
    QQC2.ButtonGroup {
        id: modeGroup
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: ds.space8 + ds.space1      // 36, the mockup's content padding
        anchors.bottomMargin: ds.space8 + ds.space1
        anchors.leftMargin: ds.space10 + ds.space1    // 44
        anchors.rightMargin: ds.space10 + ds.space1
        spacing: ds.space5

        // ---- the question, and the one thing that can change it -------------------------
        RowLayout {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            spacing: ds.space4

            ColumnLayout {
                Layout.fillWidth: true
                spacing: ds.space2

                Text {
                    Layout.fillWidth: true
                    // Not a qsTr() here: the headline carries the product name, a build fact, so
                    // C++ chooses it — the same split as the disk page's.
                    text: apps.headline
                    color: ds.textStrong
                    wrapMode: Text.WordWrap
                    font.family: ds.fontDisplay
                    font.pixelSize: ds.textHeading
                    font.weight: ds.weightBold
                    font.letterSpacing: ds.tracking(ds.trackingTight, ds.textHeading)
                }

                Text {
                    Layout.fillWidth: true
                    text: apps.subheadline
                    color: ds.textMuted
                    wrapMode: Text.WordWrap
                    font.family: ds.fontSans
                    font.pixelSize: ds.textMd
                    lineHeight: ds.leadingNormal
                    lineHeightMode: Text.ProportionalHeight
                }
            }

            // Networks come up late, and the greeting page's verdict was taken at startup. This
            // is the same re-ask the page does on every entry, for the person who plugged the
            // cable in while reading the disk page. The SHARED button for the reason the disk
            // page's own rescan gives: qqc2-desktop-style would draw Breeze's button whatever
            // Kirigami.Theme says, leaving one control that did not look like the design.
            Button {
                Layout.alignment: Qt.AlignTop
                ds: root.ds
                variant: "ghost"
                size: "sm"
                label: apps.checkAgainLabel
                onClicked: apps.recheckInternet()
            }
        }

        // ---- the state with nothing to add (the disk page's empty state, same shape) -------
        // Informational, not a warning: an offline install is a supported, first-class path
        // (greeting.conf's `required:` list deliberately omits internet), and the sentence says
        // what to do later rather than what went wrong. The design system's `info` Alert rather
        // than Kirigami.InlineMessage, which paints its own Breeze-coloured box.
        Rectangle {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            implicitHeight: offlineText.implicitHeight + 2 * ds.space3
            visible: !apps.hasInternet
            radius: ds.radiusMd
            color: ds.statusInfoBg
            border.width: ds.borderWidth
            border.color: ds.mix(ds.statusInfo, ds.statusInfoBg, 0.3)

            Text {
                id: offlineText

                anchors.fill: parent
                anchors.margins: ds.space3
                anchors.leftMargin: ds.space4
                anchors.rightMargin: ds.space4
                text: apps.offlineNote
                color: ds.textBody
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textSm
                lineHeight: ds.leadingNormal
                lineHeightMode: Text.ProportionalHeight
            }
        }

        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.maximumWidth: ds.contentMaxWidth
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                id: body

                width: Math.min(root.width - 2 * (ds.space10 + ds.space1),
                                ds.contentMaxWidth)
                spacing: ds.space6

                // ---- the three answers, as the design system's three-up card grid ------------
                GridLayout {
                    Layout.fillWidth: true
                    columns: 3
                    columnSpacing: ds.space3
                    rowSpacing: ds.space3

                    // THE CARD IS THE CONTROL. background/indicator/contentItem are all replaced,
                    // so a QQC2.RadioButton draws as a bordered card with a dot in it — and the
                    // whole card is the hit area, the keyboard target and the accessible object.
                    // A bare radio with a label beside it needed a MouseArea to make the words
                    // clickable (plan/27 §7); this needs nothing, because the words are inside.
                    component ModeCard: QQC2.RadioButton {
                        id: card

                        // `ds` AND THE GROUP ARE PASSED IN, NOT REACHED FOR. An inline component
                        // is its own component: an unqualified name inside one resolves through
                        // the parent CHAIN, which qmllint reports as "a member of a parent
                        // element" and which `pragma ComponentBehavior: Bound` exists to
                        // discourage. Handing them in as required properties makes the dependency
                        // a declaration instead of a lookup — and a lookup that silently returns
                        // undefined is a radio in no group, which is three cards that can all be
                        // selected at once.
                        required property Theme ds
                        required property var group
                        required property string modeId
                        required property string cardTitle
                        required property string cardBody

                        QQC2.ButtonGroup.group: card.group

                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        padding: card.ds.space4
                        spacing: 0

                        // `checked` is assigned imperatively by the control and its group, which
                        // breaks any binding; C++ is the source of truth and the Connections
                        // below put its answer back. onClicked rather than onToggled because the
                        // group also toggles the OTHER cards, whose handlers must not run.
                        onClicked: apps.mode = card.modeId

                        Connections {
                            target: apps
                            function onModeChanged() {
                                card.checked = (apps.mode === card.modeId);
                            }
                        }

                        Accessible.name: card.cardTitle
                        Accessible.description: card.cardBody

                        // The offline rule's UI half lives on the instances below, not here: one
                        // of the three cards is never disabled, because it is the offline answer.
                        opacity: card.enabled ? 1 : 0.5

                        HoverHandler {
                            id: cardHover
                            cursorShape: Qt.PointingHandCursor
                            enabled: card.enabled
                        }

                        background: Rectangle {
                            radius: card.ds.radiusLg
                            color: card.checked ? card.ds.accentWash : card.ds.surfaceCard
                            border.width: card.ds.borderWidth
                            border.color: card.checked || card.visualFocus
                                ? card.ds.accent
                                : (cardHover.hovered ? card.ds.borderStrong : card.ds.borderSubtle)

                            Behavior on border.color {
                                ColorAnimation { duration: card.ds.durationBase }
                            }
                        }

                        // The indicator is positioned by the style unless it is given coordinates,
                        // and this one is laid out by the content below instead — so it is taken
                        // out of the flow entirely and drawn by the row inside contentItem.
                        indicator: null

                        contentItem: ColumnLayout {
                            spacing: card.ds.space2

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: card.ds.space2 + 2

                                // 18px with a 2px ring, the design system's mark at the size the
                                // mockup's application cards use it.
                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    implicitWidth: 18
                                    implicitHeight: 18
                                    radius: width / 2
                                    color: "transparent"
                                    border.width: card.ds.borderWidthStrong
                                    border.color: card.checked ? card.ds.accent : card.ds.borderStrong

                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 8
                                        height: width
                                        radius: width / 2
                                        visible: card.checked
                                        color: card.ds.accent
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: card.cardTitle
                                    color: card.ds.textStrong
                                    wrapMode: Text.WordWrap
                                    font.family: card.ds.fontSans
                                    font.pixelSize: card.ds.textSm
                                    font.weight: card.ds.weightSemibold
                                }
                            }

                            // The configured names, not a hard-coded list: C++ joins them out of
                            // the configured app list, so the card cannot disagree with what gets
                            // installed.
                            Text {
                                Layout.fillWidth: true
                                text: card.cardBody
                                color: card.ds.textMuted
                                wrapMode: Text.WordWrap
                                font.family: card.ds.fontSans
                                font.pixelSize: card.ds.textXs
                                lineHeight: card.ds.leadingSnug
                                lineHeightMode: Text.ProportionalHeight
                            }
                        }
                    }

                    ModeCard {
                        id: typicalRadio

                        ds: root.ds
                        group: modeGroup
                        modeId: "typical"
                        cardTitle: apps.typicalTitle
                        cardBody: apps.typicalNames
                        // The offline rule's UI half: the two choices that need a connection
                        // cannot be picked while there is none. C++ refuses them anyway — this
                        // is what makes the refusal never look like a bug.
                        enabled: apps.hasInternet
                        checked: apps.mode === "typical"
                    }

                    ModeCard {
                        id: noneRadio

                        ds: root.ds
                        group: modeGroup
                        modeId: "none"
                        cardTitle: apps.noneTitle
                        cardBody: apps.noneSubtitle
                        // Never disabled: this is the offline answer, forced by C++, and it is
                        // what the page shows when a connection is found wanting.
                        checked: apps.mode === "none"
                    }

                    ModeCard {
                        id: customRadio

                        ds: root.ds
                        group: modeGroup
                        modeId: "custom"
                        cardTitle: apps.customTitle
                        cardBody: apps.customSubtitle
                        enabled: apps.hasInternet
                        checked: apps.mode === "custom"
                    }
                }

                // ---- the list the custom card opens ------------------------------------------
                // The list starts where "typical" ends — every box ticked — so choosing five of
                // six is one un-tick, not five ticks. C++ owns the set; each box pushes its own
                // change and binds back off apps.selectedIds, in file order whatever order they
                // were ticked in.
                //
                // HIDDEN RATHER THAN DIMMED, which is where this page departs from the design
                // system's own screen. That one greys the list out under the other two answers
                // and leaves the ticks showing. Here the ticks are `m_selected`, which C++ keeps
                // independently of the mode — so under "none" a dimmed list would show every
                // application ticked on a page that is about to install none of them. A page that
                // misrepresents what is going to happen is the one thing this page must not be.
                GridLayout {
                    Layout.fillWidth: true
                    // No `enabled:` of its own: the list is only reachable through the custom
                    // card above, which C++ refuses offline — one place says the rule.
                    visible: apps.mode === "custom"
                    columns: 2
                    columnSpacing: ds.space2 + 2
                    rowSpacing: ds.space2 + 2

                    Repeater {
                        model: apps.apps

                        // THE TILE IS THE CONTROL, as the mode cards above are: the box, the name
                        // and the sentence under it are one QQC2.CheckBox with everything drawn.
                        // The Flathub ID is not on the tile — it remains the key C++ and the job
                        // exchange and the thing the summary page can name, but it was never the
                        // sentence to lead with. The description is the conf's own, translated
                        // through the AppsDescriptions context.
                        QQC2.CheckBox {
                            id: appBox

                            required property var modelData

                            Layout.fillWidth: true
                            padding: ds.space3 + 2
                            leftPadding: ds.space4
                            rightPadding: ds.space4
                            spacing: 0

                            checked: apps.selectedIds.indexOf(appBox.modelData.id) !== -1
                            onToggled: apps.setSelected(appBox.modelData.id, checked)

                            Accessible.name: appBox.modelData.name
                            Accessible.description: appBox.modelData.description

                            HoverHandler {
                                id: appHover
                                cursorShape: Qt.PointingHandCursor
                            }

                            background: Rectangle {
                                radius: ds.radiusLg
                                color: appBox.checked ? ds.accentWash : ds.surfaceCard
                                border.width: ds.borderWidth
                                border.color: appBox.checked || appBox.visualFocus
                                    ? ds.accent
                                    : (appHover.hovered ? ds.borderStrong : ds.borderSubtle)

                                Behavior on border.color {
                                    ColorAnimation { duration: ds.durationBase }
                                }
                            }

                            indicator: null

                            contentItem: RowLayout {
                                spacing: ds.space3 + 2

                                // The design system's Checkbox mark: a 20px square with a 2px
                                // ring, filled with the accent and ticked when on.
                                Rectangle {
                                    Layout.alignment: Qt.AlignVCenter
                                    implicitWidth: 20
                                    implicitHeight: 20
                                    radius: ds.radiusSm
                                    color: appBox.checked ? ds.accent : "transparent"
                                    border.width: ds.borderWidthStrong
                                    border.color: appBox.checked ? ds.accent : ds.borderStrong

                                    Text {
                                        anchors.centerIn: parent
                                        visible: appBox.checked
                                        text: "✓"
                                        color: ds.accentOn
                                        font.family: ds.fontSans
                                        font.pixelSize: ds.textXs
                                        font.weight: ds.weightBold
                                    }
                                }

                                Kirigami.Icon {
                                    source: appBox.modelData.icon
                                    implicitWidth: 20
                                    implicitHeight: 20
                                    isMask: false
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 3

                                    Text {
                                        Layout.fillWidth: true
                                        text: appBox.modelData.name
                                        color: ds.textStrong
                                        elide: Text.ElideRight
                                        font.family: ds.fontSans
                                        font.pixelSize: ds.textSm
                                        font.weight: ds.weightSemibold
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        visible: appBox.modelData.description.length > 0
                                        text: appBox.modelData.description
                                        color: ds.textMuted
                                        elide: Text.ElideRight
                                        font.family: ds.fontSans
                                        font.pixelSize: ds.textXs
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
