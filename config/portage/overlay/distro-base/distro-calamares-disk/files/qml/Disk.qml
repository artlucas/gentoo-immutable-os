/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The disk page (plan/24 §1, plates 01–04).
 *
 * THE ROOT ITEM IS A PLAIN Item, for the reason Accounts.qml and Language.qml both give: this is
 * loaded into a QQuickWidget that Calamares parents into its own window, so a Kirigami
 * ApplicationWindow would be a second window that never appears and a Kirigami page assumes a
 * page stack that is not there.
 *
 * No qsTr() in this file (plan/27 §1): the builder's lupdate is built without QML support, so a
 * qsTr() here never reached the branding catalogue and rendered English in every language. Every
 * word is a tr()'d DiskConfig property instead — and never i18n(), for there is no
 * KLocalizedContext on this engine either (plan/19 §7.2).
 *
 * `disk` is the DiskConfig context property. Everything on this page is a binding onto it; the
 * only state held here is the ListView's own highlight, and that is pushed into C++ and pulled
 * back on the next line.
 *
 * ONE SCREEN, AND THE ORDER OF IT IS THE ARGUMENT (plan/24, plate 05 is the version that was not
 * taken). The list scrolls and the consequences do not: everything that follows from choosing a
 * disk — what will happen to it, and what will be lost — is pinned below the list, so the one
 * deliberate act on this page can never be the thing that is below the fold. Folding the panel
 * into the selected row reads better and behaves worse: the row grows by ~160px, every row under
 * it moves, and on a page whose one risk is clicking the wrong disk the list must not move under
 * the cursor. The agreement itself moved off the panel and into the confirmation dialog the
 * window's Next now opens (plan/26 §1), which is drawn at the bottom of this file.
 *
 * REPAINTED IN plan/28. The structure above is unchanged — this page was already the closest of
 * the five to the design system's handoff, which drew the same radio-dot rows, the same to-scale
 * layout bar with a legend under it, and the same erase dialog behind Next. What changed is that
 * every colour, radius, size and gap now comes from Theme.qml instead of from Kirigami, so the
 * page paints the brand rather than whichever Plasma ds the live session is running.
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
    // scroll bar, the delegate, the dialog; the rest reads `ds` directly.
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

    // THE ORDER IS THE DISK'S, AND C++ OWNS IT. DiskConfig::plan() returns the four segments in
    // on-disk order — boot, system, the slot kept back for the next version, everything else —
    // so this array is indexed by position and never by name. If a fifth partition is ever added
    // (plan/16 §6's swap, which is Phase B), it gets a colour here and nothing else changes.
    //
    // The ramp is the design system's own, in the order the mockup's layout bar uses it:
    // accent-soft for the small system partitions, accent for the one being written, a basalt
    // grey for the slot held back. "Your files" keeps the strongest accent on purpose — it is the
    // only segment that belongs to the person reading the page, and it is nearly all of the disk.
    readonly property var planColours: [
        ds.accentSoft,
        ds.accent,
        ds.basalt300,
        ds.accentStrong
    ]
    // The text drawn ON each segment, which has to survive whichever of the four it lands on.
    readonly property var planTextColours: [
        ds.basalt900,
        ds.accentOn,
        ds.basalt900,
        ds.accentOn
    ]
    // Three pixels of a terabyte is still a segment somebody has to be able to see. The ESP and
    // the two root slots really are 1.4% of a 1 TB disk between them, and the bar says so — the
    // honest version is also the reassuring one — but a segment with no width at all would read
    // as a missing partition rather than a small one.
    readonly property int minimumSegment: ds.space2

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
        spacing: ds.space5

        // ---- the question, and what it costs to answer it -------------------------------
        RowLayout {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            spacing: ds.space4

            ColumnLayout {
                Layout.fillWidth: true
                spacing: ds.space2

                Text {
                    Layout.fillWidth: true
                    // Not a qsTr() here: the heading depends on how many disks the machine has as
                    // well as on the language — "This computer has one disk." is a different
                    // sentence, not a translation of the first one — so C++ chooses it.
                    text: disk.headline
                    color: ds.textStrong
                    wrapMode: Text.WordWrap
                    font.family: ds.fontDisplay
                    font.pixelSize: ds.textHeading
                    font.weight: ds.weightBold
                    font.letterSpacing: ds.tracking(ds.trackingTight, ds.textHeading)
                }

                Text {
                    Layout.fillWidth: true
                    text: disk.subheadline
                    color: ds.textMuted
                    wrapMode: Text.WordWrap
                    font.family: ds.fontSans
                    font.pixelSize: ds.textMd
                    lineHeight: ds.leadingNormal
                    lineHeightMode: Text.ProportionalHeight
                }
            }

            // Disks get plugged in halfway through, and on a medium that autologins into one
            // application the only other way to re-enumerate is to quit and start again.
            //
            // The SHARED button, not a QQC2.Button, and for the same reason every other control
            // on this page is drawn: qqc2-desktop-style paints Breeze's button no matter what
            // Kirigami.Theme says about colour, so the one control left in the style's hands
            // would be the one that did not look like the design. `ghost` is the design system's
            // no-fill variant, which is what a secondary action beside a heading wants.
            Button {
                Layout.alignment: Qt.AlignTop
                ds: root.ds
                variant: "ghost"
                size: "sm"
                // The reload mark, drawn by the shared Button. "Check again" is an action whose
                // whole meaning is "do that once more", and it is the only such control in the
                // installer — the glyph says so before the sentence is read, and it is the same
                // glyph on both pages because it is the same promise.
                icon: "refresh"
                label: disk.checkAgainLabel
                onClicked: disk.rescan()
            }
        }

        // ---- the state with nothing to offer (plate 04) ----------------------------------
        // Reachable even though the greeting page already checked the disk size, because the two
        // checks are not the same question: that one asks whether ANY disk is big enough, this
        // one asks which disks are usable, and a machine whose only large disk is the stick the
        // installer booted from passes the first and fails here.
        //
        // The design system's Alert rather than Kirigami.InlineMessage, which draws its own
        // Breeze-coloured box with a Breeze icon in it: a tinted panel, a 30%-accent border in
        // the tone's own colour, and the tone's text.
        Rectangle {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            implicitHeight: noDisksText.implicitHeight + 2 * ds.space3
            visible: disk.installableCount === 0
            radius: ds.radiusMd
            color: ds.statusWarningBg
            border.width: ds.borderWidth
            border.color: ds.mix(ds.statusWarning, ds.statusWarningBg, 0.3)

            Text {
                id: noDisksText

                anchors.fill: parent
                anchors.margins: ds.space3
                anchors.leftMargin: ds.space4
                anchors.rightMargin: ds.space4
                text: disk.diskCount === 0
                    ? disk.noDisksText
                    : disk.noDisksMinimumText
                color: ds.textBody
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textSm
                lineHeight: ds.leadingNormal
                lineHeightMode: Text.ProportionalHeight
            }
        }

        // ---- the disks ------------------------------------------------------------------
        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.maximumWidth: ds.contentMaxWidth
            contentWidth: availableWidth
            clip: true

            ListView {
                id: list

                // CONSTANT, and it has to stay that way: QQuickItemViewPrivate::connectModel()
                // forces setCurrentIndex( count > 0 ? 0 : -1 ) whenever a model is assigned to a
                // view that is already complete, so a reassignable model property would select
                // row 0 behind everyone's back. On the language page that chose a language; here
                // it would choose a disk.
                model: disk.disks
                // The design system puts a 10px gutter between the cards; a ListView's spacing is
                // where that has to live, because each row is now a bordered card rather than a
                // band of a continuous list.
                spacing: ds.space2 + 2
                keyNavigationEnabled: true
                focus: true

                // THE VIEW IS THE TAB STOP, NOT THE ROWS (plan/30 §1). QQuickItemDelegate calls
                // setFocusPolicy(Qt::NoFocus) in its own constructor, so a delegate never takes
                // focus and never will — which is the right shape for a list (twelve disks would
                // otherwise be twelve tab stops) and was also why the focus ring below, bound to
                // `visualFocus`, could not once have appeared. Tab lands on the VIEW; the arrow
                // keys move within it; the ring is drawn on whichever row is current while the
                // view holds focus.
                activeFocusOnTab: true

                // -1 EXPLICITLY. QQuickItemView::componentComplete() runs
                //     if ( currentIndex < 0 && !currentIndexCleared ) updateCurrent( 0 );
                // and setCurrentIndex() sets currentIndexCleared = ( index == -1 ) BEFORE its
                // early return, so writing -1 here is the only thing that stops the view choosing
                // the first row for itself. The language page paid for this line with an
                // installer that opened in German (plan/22 §9); this page would pay for it by
                // pre-selecting somebody's disk.
                currentIndex: -1

                // NEITHER DIRECTION IS A BINDING, and neither can be: ListView assigns
                // currentIndex itself on every arrow key, which would break a binding permanently.
                // Two imperative handlers, and they cannot ring — DiskConfig::setCurrentIndex()
                // returns without a signal when the value has not changed.
                Component.onCompleted: list.currentIndex = disk.currentIndex
                onCurrentIndexChanged: disk.currentIndex = list.currentIndex

                Connections {
                    target: disk
                    // C++ -> QML, because C++ is allowed to REFUSE. setCurrentIndex() drops any
                    // row that is not installable, and without this the view would go on drawing
                    // a disk as chosen that the installer would never write to. It is also what
                    // puts the highlight on the single disk C++ selects for the user when there
                    // is only one.
                    function onCurrentIndexChanged() {
                        list.currentIndex = disk.currentIndex;
                    }
                }

                delegate: QQC2.ItemDelegate {
                    id: row

                    required property int index
                    required property string title
                    required property string node
                    required property string sizeText
                    required property string contents
                    required property bool blocked
                    required property bool removable

                    width: ListView.view ? ListView.view.width : implicitWidth
                    highlighted: ListView.isCurrentItem

                    // WHERE THE KEYBOARD IS, which on a view whose rows cannot hold focus is not
                    // a property of the row: it is the current row AND a view that has focus.
                    // `visualFocus` stood here and was always false — see the note on
                    // activeFocusOnTab above.
                    readonly property bool keyboardFocus: list.activeFocus && row.highlighted
                    hoverEnabled: !row.blocked
                    // GREYED, NOT HIDDEN (plan/24, Q3). A disabled delegate still reads to a
                    // screen reader and still occupies its place in the list, which is the whole
                    // point: the medium's own disk is in here, saying why it cannot be chosen.
                    // The design system's disabled state is 0.5 opacity and a not-allowed cursor;
                    // the badge below says which of the two greyed rows is which.
                    enabled: !row.blocked
                    opacity: row.blocked ? 0.5 : 1
                    topPadding: ds.space4
                    bottomPadding: ds.space4
                    leftPadding: ds.space5 - 2
                    rightPadding: ds.space5 - 2

                    // The view, never disk.currentIndex — the language page's finding
                    // (plan/22 §9): a QQC2.ItemDelegate does not move its view's currentIndex when
                    // clicked, so writing to C++ here would change the disk and leave the
                    // highlight wherever the keyboard had last put it.
                    onClicked: list.currentIndex = row.index

                    Accessible.role: Accessible.RadioButton
                    Accessible.checked: row.highlighted
                    Accessible.name: row.title
                    Accessible.description: row.contents

                    // HAND-BUILT, for plan/21 §1b's reason: a delegate's background is a style
                    // decision, and Fusion fills it with palette.base — an opaque slab per row
                    // over the page's own ground. Since plan/28 it is also the design system's
                    // card: a 1px border that carries the whole selected/hover/rest distinction,
                    // with the accent wash behind it when chosen. The design favours borders over
                    // fills throughout, which is why hover moves the border and not the ground.
                    background: Rectangle {
                        radius: ds.radiusLg
                        color: row.highlighted ? ds.accentWash : ds.surfaceCard
                        border.width: ds.borderWidth
                        border.color: row.keyboardFocus
                            ? ds.accent
                            : (row.highlighted
                                ? ds.accent
                                : (row.hovered ? ds.borderStrong : ds.borderSubtle))

                        Behavior on border.color {
                            ColorAnimation { duration: ds.durationBase }
                        }

                        // The focus ring, which is the one state a border colour alone cannot
                        // carry — a keyboard user tabbing through has to be able to see where
                        // they are even on the row that is already selected.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -3
                            visible: row.keyboardFocus
                            radius: ds.radiusLg + 3
                            color: "transparent"
                            border.width: 3
                            border.color: ds.mix(ds.accent, ds.surfaceCard, 0.4)
                        }
                    }

                    contentItem: RowLayout {
                        spacing: ds.space4

                        // Drawn rather than a QQC2.RadioButton, because the DELEGATE is the
                        // control: a real radio button inside it would take the click for itself
                        // and give the row two hit targets with one meaning. The role is declared
                        // on the delegate above, which is what assistive technology reads.
                        // 20px with a 2px ring is the design system's Radio, to the pixel.
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: 20
                            implicitHeight: 20
                            radius: width / 2
                            color: "transparent"
                            border.width: ds.borderWidthStrong
                            border.color: row.highlighted ? ds.accent : ds.borderStrong

                            Rectangle {
                                anchors.centerIn: parent
                                width: 10
                                height: width
                                radius: width / 2
                                visible: row.highlighted
                                color: ds.accent
                            }
                        }

                        Kirigami.Icon {
                            source: row.removable ? "drive-removable-media" : "drive-harddisk"
                            implicitWidth: 20
                            implicitHeight: 20
                            color: ds.textMuted
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 3

                            Text {
                                Layout.fillWidth: true
                                text: row.title
                                color: ds.textStrong
                                elide: Text.ElideRight
                                font.family: ds.fontSans
                                font.pixelSize: ds.textBase
                                font.weight: ds.weightSemibold
                            }

                            // ONE MONO LINE, COMPOSED HERE, and the separator is punctuation
                            // rather than a translatable string — the same bargain the legend
                            // below already strikes when it joins a label to a size. The three
                            // parts are the three facts somebody identifies a disk by: where it
                            // is, how big it is, and what is on it. `contents` is the only one
                            // that can be empty, so it is the only one that needs the guard.
                            Text {
                                Layout.fillWidth: true
                                text: row.contents.length > 0
                                    ? row.node + " \u00b7 " + row.sizeText + " \u00b7 " + row.contents
                                    : row.node + " \u00b7 " + row.sizeText
                                color: ds.textMuted
                                elide: Text.ElideRight
                                font.family: ds.fontMono
                                font.pixelSize: ds.textXs
                            }
                        }

                        // The badge, and it appears on the rows that CANNOT be chosen only. An
                        // installable disk gets nothing in this slot on purpose: the installer
                        // does not rank disks, so a "Recommended" chip would be an opinion it has
                        // not got. What it does have is a reason the medium's own stick is greyed
                        // out, and until plan/28 that reason was drawn as opacity and nothing else.
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            visible: row.blocked
                            implicitWidth: blockedBadge.implicitWidth + 2 * ds.space2
                            implicitHeight: 20
                            radius: ds.radiusSm
                            color: ds.surfaceSunken

                            Text {
                                id: blockedBadge

                                anchors.centerIn: parent
                                text: disk.notEligibleLabel
                                color: ds.textBody
                                font.family: ds.fontSans
                                font.pixelSize: ds.textXs
                                font.weight: ds.weightSemibold
                            }
                        }
                    }
                }
            }
        }

        // ---- what will happen to it -------------------------------------------------------
        ColumnLayout {
            id: panel

            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            spacing: ds.space3
            visible: disk.plan.length > 0

            // THE INSET PANEL. In the light ds `surfacePage` is the grey and `surfaceCard` is
            // the white the page sits on, so an inset reads as grey-on-white — the inverse of the
            // dark ds's nesting, and the thing to remember before changing either token.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: planBody.implicitHeight + 2 * (ds.space5 - 2)
                radius: ds.radiusLg
                color: ds.surfacePage
                border.width: ds.borderWidth
                border.color: ds.borderSubtle

                ColumnLayout {
                    id: planBody

                    anchors.fill: parent
                    anchors.margins: ds.space5 - 2
                    spacing: ds.space3

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: ds.space4

                        // The design system's eyebrow: small, mono, upper case, widely tracked.
                        // It is the one place the system uses capitals at all.
                        Text {
                            Layout.fillWidth: true
                            text: disk.layoutSummaryLabel.toUpperCase()
                            color: ds.textMuted
                            elide: Text.ElideRight
                            font.family: ds.fontMono
                            font.pixelSize: 11
                            font.letterSpacing: ds.tracking(ds.trackingCaps, 11)
                        }

                        Text {
                            text: disk.selectedDiskTitle
                            color: ds.textMuted
                            font.family: ds.fontMono
                            font.pixelSize: ds.textXs
                        }
                    }

                    // TO SCALE, deliberately. See the note on minimumSegment: the three small
                    // segments really are about a hundredth of a modern disk, and a bar that
                    // pretended otherwise would misrepresent the one fact the user cares about —
                    // almost all of it stays theirs. The sizes are written out underneath, where
                    // they can be read.
                    Rectangle {
                        id: bar

                        Layout.fillWidth: true
                        implicitHeight: 34
                        radius: ds.radiusSm
                        color: ds.surfaceCard
                        border.width: ds.borderWidth
                        border.color: ds.borderSubtle
                        // The segments are square-cornered and the bar is not, so the ends have
                        // to be cut rather than drawn.
                        clip: true

                        // The last segment takes the remainder rather than its own rounded share,
                        // so the bar always ends exactly at the right edge however the divisions
                        // fall.
                        function segmentWidth(i) {
                            let total = 0;
                            for (let k = 0; k < disk.plan.length; ++k) {
                                total += disk.plan[k].bytes;
                            }
                            if (total <= 0 || bar.width <= 0) {
                                return 0;
                            }
                            if (i === disk.plan.length - 1) {
                                let used = 0;
                                for (let j = 0; j < disk.plan.length - 1; ++j) {
                                    used += Math.max(root.minimumSegment, bar.width * disk.plan[j].bytes / total);
                                }
                                return Math.max(root.minimumSegment, bar.width - used);
                            }
                            return Math.max(root.minimumSegment, bar.width * disk.plan[i].bytes / total);
                        }

                        Row {
                            anchors.fill: parent
                            anchors.margins: ds.borderWidth

                            Repeater {
                                model: disk.plan

                                Rectangle {
                                    id: segment

                                    required property int index
                                    required property var modelData

                                    width: bar.segmentWidth(index)
                                    height: parent.height
                                    // No divider between segments, and no gap either: a gap would
                                    // read as unallocated space, which is the one thing this
                                    // layout never has.
                                    color: root.planColours[index % root.planColours.length]
                                    clip: true

                                    // The segment's own name, drawn on it where it fits. The
                                    // three small partitions are a few pixels wide on a modern
                                    // disk, so this is almost always the last segment only — and
                                    // the legend under the bar is what names the rest. `visible`
                                    // rather than elide: half a word inside a 4px sliver is
                                    // noise, not information.
                                    Text {
                                        anchors.centerIn: parent
                                        visible: segment.width > implicitWidth + ds.space2
                                        text: segment.modelData.label
                                        color: root.planTextColours[segment.index % root.planTextColours.length]
                                        font.family: ds.fontMono
                                        font.pixelSize: 10
                                    }
                                }
                            }
                        }
                    }

                    Flow {
                        Layout.fillWidth: true
                        spacing: ds.space4

                        Repeater {
                            model: disk.plan

                            Row {
                                id: legendItem

                                required property int index
                                required property var modelData

                                spacing: 7

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 9
                                    height: width
                                    radius: 2
                                    color: root.planColours[legendItem.index % root.planColours.length]
                                }

                                // The label and the size as one string rather than two Texts:
                                // they are one phrase, and a Flow would otherwise be free to
                                // break between them.
                                Text {
                                    text: legendItem.modelData.label + " " + legendItem.modelData.sizeText
                                    color: ds.textBody
                                    font.family: ds.fontSans
                                    font.pixelSize: ds.textXs
                                }
                            }
                        }
                    }
                }
            }

            // ---- what is actually being lost, named (plan/24 §2; the dialog asks, plan/26 §1) --
            // This is the sentence somebody needs in front of them before they answer the
            // question the window's Next now asks, and it is built from what the row they chose
            // already said. The dialog repeats it; the panel keeps it, because the dialog is a
            // moment and the panel is the whole time the disk is chosen.
            // The design system's `warning` Alert, because this sentence is the page's one piece
            // of bad news and the system has a tone for that. It is a panel rather than loose
            // text for the same reason the dialog repeats it: the eye has to land on it.
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: lossText.implicitHeight + 2 * ds.space3
                visible: disk.lossSummary.length > 0
                radius: ds.radiusMd
                color: ds.statusWarningBg
                border.width: ds.borderWidth
                border.color: ds.mix(ds.statusWarning, ds.statusWarningBg, 0.35)

                Text {
                    id: lossText

                    anchors.fill: parent
                    anchors.margins: ds.space3
                    anchors.leftMargin: ds.space4
                    anchors.rightMargin: ds.space4
                    text: disk.lossSummary
                    color: ds.textBody
                    wrapMode: Text.WordWrap
                    font.family: ds.fontSans
                    font.pixelSize: ds.textSm
                    lineHeight: ds.leadingNormal
                    lineHeightMode: Text.ProportionalHeight
                }
            }

            // ---- encryption, drawn and disabled (plan/24 §7) ------------------------------
            // Visible on purpose. Hiding it would mean the first person to ask about encryption
            // has to ask whether it was forgotten; showing it disabled, with a reason, answers
            // that without a release note. The design system's disabled state is the 0.5 opacity
            // below, which is why nothing here dims itself a second time.
            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: ds.space1
                spacing: ds.space3
                enabled: disk.encryptionAvailable
                opacity: disk.encryptionAvailable ? 1 : 0.5

                Kirigami.Icon {
                    source: "object-locked"
                    implicitWidth: 16
                    implicitHeight: 16
                    color: ds.textMuted
                }

                Text {
                    text: disk.encryptLabel
                    color: ds.textStrong
                    font.family: ds.fontSans
                    font.pixelSize: ds.textSm
                    font.weight: ds.weightMedium
                }

                Text {
                    Layout.fillWidth: true
                    visible: !disk.encryptionAvailable
                    text: disk.notYetAvailableText
                    color: ds.textMuted
                    elide: Text.ElideRight
                    font.family: ds.fontSans
                    font.pixelSize: ds.textXs
                }

                // The design system's Switch, hand-drawn for the reason the rescan button gives:
                // qqc2-desktop-style would paint Breeze's. 40x24 with a 20px thumb, to the pixel.
                Rectangle {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: 40
                    implicitHeight: 24
                    radius: ds.radiusPill
                    color: ds.basalt300

                    Rectangle {
                        x: 2
                        y: 2
                        width: 20
                        height: 20
                        radius: ds.radiusPill
                        color: ds.white
                    }
                }
            }
        }
    }

    // ---- the question the window's Next now asks (plan/26 §1) --------------------------------
    //
    // This replaces the confirmation checkbox (plan/24 §2), and the mechanism is the accounts
    // page's pager worn as a dialog: ViewManager::next() calls this step's next() — which is
    // DiskConfig::requestConfirmation(), the signal the Connections below listens for — instead
    // of leaving the page for as long as isAtEnd() is false, and isAtEnd() is disk.confirmed,
    // which only "Erase and install" sets. Accepting completes the advance from C++ (the view
    // step hears confirmedChanged and calls ViewManager::next() again, the call that leaves),
    // and onLeave() withdraws the answer the moment the page is left — so the question is asked
    // on EVERY press, going Back and returning no less than the first time through.
    //
    // A PromptDialog rather than a plain Dialog for the shape the KCM already uses
    // (distro-kcm-managed's leaveDialog): a title, a wrapped paragraph, and two named actions.
    Kirigami.PromptDialog {
        id: confirmDialog

        title: disk.confirmTitle
        // The disk by the name the row used, then the loss summary — composed whole in C++
        // (confirmSubtitle), so the same two sentences the page below the dialog already says
        // cannot diverge from it in a second language, and every word of this dialog follows
        // the catalogue (plan/27 §1).
        subtitle: disk.confirmSubtitle
        standardButtons: Kirigami.Dialog.NoButton
        customFooterActions: [
            Kirigami.Action {
                icon.name: "dialog-cancel"
                text: disk.cancelLabel
                onTriggered: confirmDialog.close()
            },
            Kirigami.Action {
                icon.name: "data-warning"
                text: disk.confirmAcceptLabel
                onTriggered: {
                    confirmDialog.close();
                    disk.acceptConfirmation();
                }
            }
        ]

        Connections {
            target: disk
            function onConfirmationRequested() {
                confirmDialog.open();
            }
            // The withdrawn-answer cases — leaving the page (including by the window's Back,
            // from under an open dialog), changing the disk, rescanning — all arrive here as
            // confirmed going false, which is what closes a dialog nobody answered.
            function onConfirmedChanged() {
                if ( !disk.confirmed )
                {
                    confirmDialog.close();
                }
            }
        }
    }
}
