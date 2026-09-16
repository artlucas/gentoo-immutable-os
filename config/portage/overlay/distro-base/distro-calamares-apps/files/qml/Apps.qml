/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The applications page (plan/25).
 *
 * THE ROOT ITEM IS A PLAIN Item, for the reason Disk.qml gives: this is loaded into a QQuickWidget
 * that Calamares parents into its own window, so a Kirigami ApplicationWindow would be a second
 * window that never appears and a Kirigami page assumes a page stack that is not there.
 *

 * `apps` is the AppsConfig context property. THE MODE IS C++'s, the disk page's rule: the three
 * radios are drawn from apps.mode and push their clicks into it, because two sources of truth for
 * one choice is how a summary page comes to say "Typical application set" about an install that
 * shipped none. The custom list's checkboxes bind off apps.selectedIds the same way, per box.
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

    // The three answers are exclusive; RadioButtons in different rows are not siblings, so the
    // group is named rather than left to parent-based auto-exclusivity.
    QQC2.ButtonGroup {
        id: modeGroup
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing

        // ---- the question, and the one thing that can change it -------------------------
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
                    // Not a qsTr() here: the headline carries the product name, a build fact, so
                    // C++ chooses it — the same split as the disk page's.
                    text: apps.headline
                }

                QQC2.Label {
                    Layout.fillWidth: true
                    text: apps.subheadline
                    wrapMode: Text.WordWrap
                    opacity: 0.75
                    font: Kirigami.Theme.smallFont
                }
            }

            // Networks come up late, and the greeting page's verdict was taken at startup. This
            // is the same re-ask the page does on every entry, for the person who plugged the
            // cable in while reading the disk page.
            QQC2.Button {
                Layout.alignment: Qt.AlignTop
                flat: true
                icon.name: "view-refresh"
                text: apps.checkAgainLabel
                onClicked: apps.recheckInternet()
            }
        }

        Kirigami.Separator {
            Layout.fillWidth: true
        }

        // ---- the state with nothing to add (the disk page's empty state, same shape) -------
        // Informational, not a warning: an offline install is a supported, first-class path
        // (greeting.conf's `required:` list deliberately omits internet), and the sentence says
        // what to do later rather than what went wrong.
        Kirigami.InlineMessage {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            visible: !apps.hasInternet
            type: Kirigami.MessageType.Information
            text: apps.offlineNote
        }

        QQC2.ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: root.width - 2 * Kirigami.Units.largeSpacing
                spacing: Kirigami.Units.smallSpacing

                // ---- typical -----------------------------------------------------------------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    QQC2.RadioButton {
                        id: typicalRadio

                        QQC2.ButtonGroup.group: modeGroup
                        // The offline rule's UI half: the two choices that need a connection
                        // cannot be picked while there is none. C++ refuses them anyway — this
                        // is what makes the refusal never look like a bug.
                        enabled: apps.hasInternet
                        // checked is assigned imperatively by the control and its group, which
                        // breaks any binding; C++ is the source of truth and the Connections
                        // below put its answer back. onClicked rather than onToggled because
                        // the group also toggles the OTHER radios, whose handlers must not run.
                        checked: apps.mode === "typical"
                        onClicked: apps.mode = "typical"

                        Connections {
                            target: apps
                            function onModeChanged() {
                                typicalRadio.checked = (apps.mode === "typical");
                            }
                        }

                        Accessible.name: apps.typicalTitle
                        Accessible.description: apps.typicalNames
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        QQC2.Label {
                            Layout.fillWidth: true
                            text: apps.typicalTitle
                            wrapMode: Text.WordWrap
                            font.bold: typicalRadio.checked
                            opacity: apps.hasInternet ? 1 : 0.5
                        }

                        // The configured names, not a hard-coded list: C++ joins them out of the
                        // configured app list, so the row cannot disagree with what gets installed.
                        QQC2.Label {
                            Layout.fillWidth: true
                            text: apps.typicalNames
                            wrapMode: Text.WordWrap
                            opacity: apps.hasInternet ? 0.7 : 0.35
                            font: Kirigami.Theme.smallFont
                        }
                    }
                }

                // ---- none --------------------------------------------------------------------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    QQC2.RadioButton {
                        id: noneRadio

                        QQC2.ButtonGroup.group: modeGroup
                        // Never disabled: this is the offline answer, forced by C++, and it is
                        // what the page shows when a connection is found wanting.
                        checked: apps.mode === "none"
                        onClicked: apps.mode = "none"

                        Connections {
                            target: apps
                            function onModeChanged() {
                                noneRadio.checked = (apps.mode === "none");
                            }
                        }

                        Accessible.name: apps.noneTitle
                    }

                    QQC2.Label {
                        Layout.fillWidth: true
                        text: apps.noneSubtitle
                        wrapMode: Text.WordWrap
                        opacity: 0.7
                        font: Kirigami.Theme.smallFont
                    }
                }

                Kirigami.Separator {
                    Layout.fillWidth: true
                }

                // ---- custom, and the list it opens -------------------------------------------
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing

                    QQC2.RadioButton {
                        id: customRadio

                        QQC2.ButtonGroup.group: modeGroup
                        enabled: apps.hasInternet
                        checked: apps.mode === "custom"
                        onClicked: apps.mode = "custom"

                        Connections {
                            target: apps
                            function onModeChanged() {
                                customRadio.checked = (apps.mode === "custom");
                            }
                        }

                        Accessible.name: apps.customTitle
                    }

                    QQC2.Label {
                        Layout.fillWidth: true
                        text: apps.customSubtitle
                        wrapMode: Text.WordWrap
                        opacity: apps.hasInternet ? 0.7 : 0.35
                        font: Kirigami.Theme.smallFont
                    }
                }

                // The list starts where "typical" ends — every box ticked — so choosing five of
                // six is one un-tick, not five ticks. C++ owns the set; each box pushes its own
                // change and binds back off apps.selectedIds, in file order whatever order they
                // were ticked in.
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: Kirigami.Units.gridUnit
                    // No `enabled:` of its own: the list is only reachable through the custom
                    // radio above, which C++ refuses offline — one place says the rule.
                    visible: apps.mode === "custom"
                    spacing: Kirigami.Units.smallSpacing

                    Repeater {
                        model: apps.apps

                        RowLayout {
                            id: appRow

                            required property var modelData

                            Layout.fillWidth: true
                            spacing: Kirigami.Units.smallSpacing

                            QQC2.CheckBox {
                                checked: apps.selectedIds.indexOf(appRow.modelData.id) !== -1
                                onToggled: apps.setSelected(appRow.modelData.id, checked)

                                Accessible.name: appRow.modelData.name
                            }

                            Kirigami.Icon {
                                source: appRow.modelData.icon
                                implicitWidth: Kirigami.Units.iconSizes.smallMedium
                                implicitHeight: Kirigami.Units.iconSizes.smallMedium
                                isMask: false
                            }

                            QQC2.Label {
                                Layout.fillWidth: true
                                text: appRow.modelData.name
                                elide: Text.ElideRight
                            }

                            // The Flathub ID, for the people who already know which one they
                            // want. Small and dim: it is an identifier, not a name.
                            QQC2.Label {
                                text: appRow.modelData.id
                                opacity: 0.6
                                font: Kirigami.Theme.smallFont
                            }
                        }
                    }
                }
            }
        }
    }
}
