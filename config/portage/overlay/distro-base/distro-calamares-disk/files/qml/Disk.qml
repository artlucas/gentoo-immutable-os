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
 * qsTr(), never i18n() — there is no KLocalizedContext on this engine (plan/19 §7.2).
 *
 * `disk` is the DiskConfig context property. Everything on this page is a binding onto it; the
 * only state held here is the ListView's own highlight, and that is pushed into C++ and pulled
 * back on the next line.
 *
 * ONE SCREEN, AND THE ORDER OF IT IS THE ARGUMENT (plan/24, plate 05 is the version that was not
 * taken). The list scrolls and the consequences do not: everything that follows from choosing a
 * disk — what will happen to it, what will be lost, and the checkbox that agrees to it — is
 * pinned below the list, so the one deliberate act on this page can never be the thing that is
 * below the fold. Folding the panel into the selected row reads better and behaves worse: the row
 * grows by ~160px, every row under it moves, and on a page whose one risk is clicking the wrong
 * disk the list must not move under the cursor.
 *
 * Measured against the viewport Calamares gives a view module — 710x536, the 900x600 branding
 * window less the 190px sidebar and the 64px navigation bar — the header is 44px, the panel is
 * ~175px, and the list gets what is left: four rows of five visible, with the fifth scrolled.
 */
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Item {
    id: root

    // THE ORDER IS THE DISK'S, AND C++ OWNS IT. DiskConfig::plan() returns the four segments in
    // on-disk order — boot, system, the slot kept back for the next version, everything else —
    // so this array is indexed by position and never by name. If a fifth partition is ever added
    // (plan/16 §6's swap, which is Phase B), it gets a colour here and nothing else changes.
    //
    // "Your files" is the positive colour on purpose: it is the only segment that belongs to the
    // person reading the page, and it is nearly all of the disk.
    readonly property var planColours: [
        Kirigami.Theme.disabledTextColor,
        Kirigami.Theme.highlightColor,
        Qt.alpha(Kirigami.Theme.highlightColor, 0.45),
        Kirigami.Theme.positiveTextColor
    ]
    // Three pixels of a terabyte is still a segment somebody has to be able to see. The ESP and
    // the two root slots really are 1.4% of a 1 TB disk between them, and the bar says so — the
    // honest version is also the reassuring one — but a segment with no width at all would read
    // as a missing partition rather than a small one.
    readonly property int minimumSegment: Kirigami.Units.smallSpacing

    // Calamares' window paints nothing behind this widget, so the page paints its own ground.
    Rectangle {
        anchors.fill: parent
        color: Kirigami.Theme.backgroundColor
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing

        // ---- the question, and what it costs to answer it -------------------------------
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Kirigami.Heading {
                    Layout.fillWidth: true
                    level: 3
                    wrapMode: Text.WordWrap
                    // Not a qsTr() here: the heading depends on how many disks the machine has as
                    // well as on the language — "This computer has one disk." is a different
                    // sentence, not a translation of the first one — so C++ chooses it.
                    text: disk.headline
                }

                QQC2.Label {
                    Layout.fillWidth: true
                    text: disk.subheadline
                    wrapMode: Text.WordWrap
                    opacity: 0.75
                    font: Kirigami.Theme.smallFont
                }
            }

            // Disks get plugged in halfway through, and on a medium that autologins into one
            // application the only other way to re-enumerate is to quit and start again.
            QQC2.Button {
                Layout.alignment: Qt.AlignTop
                flat: true
                icon.name: "view-refresh"
                text: qsTr("Check again")
                onClicked: disk.rescan()
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        // ---- the state with nothing to offer (plate 04) ----------------------------------
        // Reachable even though the greeting page already checked the disk size, because the two
        // checks are not the same question: that one asks whether ANY disk is big enough, this
        // one asks which disks are usable, and a machine whose only large disk is the stick the
        // installer booted from passes the first and fails here.
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            visible: disk.installableCount === 0
            type: Kirigami.MessageType.Warning
            text: disk.diskCount === 0
                ? qsTr("No disks were found at all.")
                : qsTr("Plug in a disk of at least %1 and choose Check again. These are the disks this computer has now:").arg(disk.minimumSizeText)
        }

        // ---- the disks ------------------------------------------------------------------
        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: Kirigami.Units.smallSpacing
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
                spacing: 0
                keyNavigationEnabled: true
                focus: true

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
                    hoverEnabled: !row.blocked
                    // GREYED, NOT HIDDEN (plan/24, Q3). A disabled delegate still reads to a
                    // screen reader and still occupies its place in the list, which is the whole
                    // point: the medium's own disk is in here, saying why it cannot be chosen.
                    enabled: !row.blocked
                    padding: Kirigami.Units.smallSpacing
                    leftPadding: Kirigami.Units.largeSpacing
                    rightPadding: Kirigami.Units.largeSpacing

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
                    // over the page's own ground.
                    background: Rectangle {
                        radius: Kirigami.Units.cornerRadius
                        color: row.highlighted
                            ? Qt.alpha(Kirigami.Theme.highlightColor, 0.15)
                            : (row.hovered ? Qt.alpha(Kirigami.Theme.hoverColor, 0.25)
                                           : "transparent")
                        border.width: row.highlighted || row.visualFocus ? 1 : 0
                        border.color: row.visualFocus ? Kirigami.Theme.focusColor
                                                      : Kirigami.Theme.highlightColor

                        // The accent rail, as on the language page: the one mark on the row that
                        // survives a theme with no colour difference between the states.
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

                        // Drawn rather than a QQC2.RadioButton, because the DELEGATE is the
                        // control: a real radio button inside it would take the click for itself
                        // and give the row two hit targets with one meaning. The role is declared
                        // on the delegate above, which is what assistive technology reads.
                        Rectangle {
                            Layout.alignment: Qt.AlignVCenter
                            implicitWidth: Kirigami.Units.iconSizes.small
                            implicitHeight: Kirigami.Units.iconSizes.small
                            radius: width / 2
                            color: "transparent"
                            border.width: 1
                            border.color: row.highlighted ? Kirigami.Theme.highlightColor
                                                          : Kirigami.Theme.disabledTextColor
                            opacity: row.blocked ? 0.4 : 1

                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width / 2
                                height: width
                                radius: width / 2
                                visible: row.highlighted
                                color: Kirigami.Theme.highlightColor
                            }
                        }

                        Kirigami.Icon {
                            source: row.removable ? "drive-removable-media" : "drive-harddisk"
                            implicitWidth: Kirigami.Units.iconSizes.medium
                            implicitHeight: Kirigami.Units.iconSizes.medium
                            opacity: row.blocked ? 0.5 : 1
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: Kirigami.Units.smallSpacing

                                QQC2.Label {
                                    Layout.fillWidth: true
                                    text: row.title
                                    font.bold: row.highlighted
                                    elide: Text.ElideRight
                                }

                                // The device node, for the people who already know which disk
                                // they want. Small and dim: it is an identifier, not a name.
                                QQC2.Label {
                                    text: row.node
                                    opacity: 0.6
                                    font: Kirigami.Theme.smallFont
                                }
                            }

                            QQC2.Label {
                                Layout.fillWidth: true
                                text: row.contents
                                opacity: 0.7
                                font: Kirigami.Theme.smallFont
                                elide: Text.ElideRight
                            }
                        }

                        QQC2.Label {
                            text: row.sizeText
                            font.bold: row.highlighted
                        }
                    }
                }
            }
        }

        // ---- what will happen to it -------------------------------------------------------
        ColumnLayout {
            id: panel

            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing
            visible: disk.plan.length > 0

            Kirigami.Separator {
                Layout.fillWidth: true
            }

            QQC2.Label {
                text: qsTr("The disk will be set up like this")
                font.bold: true
            }

            // TO SCALE, deliberately. See the note on minimumSegment: the three small segments
            // really are about a hundredth of a modern disk, and a bar that pretended otherwise
            // would misrepresent the one fact the user cares about — almost all of it stays
            // theirs. The sizes are written out underneath, where they can be read.
            Item {
                id: bar

                Layout.fillWidth: true
                implicitHeight: Kirigami.Units.gridUnit

                // The last segment takes the remainder rather than its own rounded share, so the
                // bar always ends exactly at the right edge however the divisions fall.
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

                    Repeater {
                        model: disk.plan

                        Rectangle {
                            required property int index
                            required property var modelData

                            width: bar.segmentWidth(index)
                            height: bar.height
                            // No divider between segments, and no gap either: a gap would read
                            // as unallocated space, which is the one thing this layout never has.
                            color: root.planColours[index % root.planColours.length]
                        }
                    }
                }
            }

            Flow {
                Layout.fillWidth: true
                spacing: Kirigami.Units.largeSpacing

                Repeater {
                    model: disk.plan

                    Row {
                        id: legendItem

                        required property int index
                        required property var modelData

                        spacing: Kirigami.Units.smallSpacing

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Kirigami.Units.smallSpacing * 2
                            height: width
                            radius: 2
                            color: root.planColours[legendItem.index % root.planColours.length]
                        }

                        // The label and the size as one string rather than two Labels: they are
                        // one phrase, and a Flow would otherwise be free to break between them.
                        QQC2.Label {
                            text: legendItem.modelData.label + " " + legendItem.modelData.sizeText
                            font: Kirigami.Theme.smallFont
                            opacity: 0.85
                        }
                    }
                }
            }

            // ---- the one deliberate act on the page (plan/24 §2) --------------------------
            QQC2.CheckBox {
                id: confirmBox

                Layout.topMargin: Kirigami.Units.smallSpacing
                text: qsTr("Erase this disk and everything on it")
                // Not a binding on `checked`: a QQC2 control assigns `checked` imperatively when
                // clicked, which would break one. C++ is the source of truth — it clears the box
                // whenever the selected disk changes, because the agreement was about a disk —
                // and the two handlers below keep the pair in step without ringing.
                checked: disk.confirmed
                onToggled: disk.confirmed = confirmBox.checked

                Connections {
                    target: disk
                    function onConfirmedChanged() {
                        confirmBox.checked = disk.confirmed;
                    }
                }
            }

            // What is actually being lost, named. This is the sentence somebody needs in front of
            // them before they tick the box above, and it is built from what the row they chose
            // already said.
            QQC2.Label {
                Layout.fillWidth: true
                Layout.leftMargin: Kirigami.Units.gridUnit
                text: disk.lossSummary
                visible: text.length > 0
                wrapMode: Text.WordWrap
                font: Kirigami.Theme.smallFont
                color: Kirigami.Theme.neutralTextColor
            }

            // ---- encryption, drawn and disabled (plan/24 §7) ------------------------------
            // Visible on purpose. Hiding it would mean the first person to ask about encryption
            // has to ask whether it was forgotten; showing it disabled, with a reason, answers
            // that without a release note.
            Kirigami.Separator {
                Layout.fillWidth: true
                Layout.topMargin: Kirigami.Units.smallSpacing
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                enabled: disk.encryptionAvailable

                Kirigami.Icon {
                    source: "object-locked"
                    implicitWidth: Kirigami.Units.iconSizes.small
                    implicitHeight: Kirigami.Units.iconSizes.small
                }

                QQC2.Label {
                    text: qsTr("Encrypt this disk")
                }

                QQC2.Label {
                    Layout.fillWidth: true
                    visible: !disk.encryptionAvailable
                    text: qsTr("Not yet available")
                    opacity: 0.7
                    font: Kirigami.Theme.smallFont
                }

                QQC2.Switch {
                    checked: false
                }
            }
        }
    }
}
