/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The accounts page (plan/21 §1).
 *
 * THE ROOT ITEM IS A PLAIN Item, not a Kirigami.ApplicationWindow and not a Kirigami page. This
 * file is loaded into a QQuickWidget that Calamares parents into its own window: an
 * ApplicationWindow inside a widget is a second window that never appears, and a
 * Kirigami.ScrollablePage assumes a page stack that is not there. Kirigami still supplies
 * everything that matters here — Units, Theme, FormLayout, InlineMessage, PasswordField — and the
 * desktop style comes from qqc2-desktop-style, asked for once in AccountsViewStep's constructor.
 * That is load-bearing rather than cosmetic: Kirigami picks its platform integration plugin from
 * the style's name, and that plugin is what initialises the icon theme, so under any other style
 * this page has no icons at all (plan/21 §1b, measured in a VM).
 *
 * qsTr(), never i18n(). plan/19 §7.2 measured what i18n() does with no KLocalizedContext on the
 * engine: a ReferenceError and an empty string. Calamares is a C++ host and could install one,
 * at the cost of a ki18n dependency this page has no other use for; Qt's own macros are already
 * wired into libcalamares' translation machinery.
 *
 * `accounts` is the AccountsConfig context property. Every field below is a two-way binding onto
 * it, so this file holds no state of its own except which disclosure triangle is open.
 *
 * TWO SCREENS, ONE VIEW STEP, AND THE INSTALLER'S OWN BUTTONS DRIVE THEM.
 *
 * The choice is on its own screen and the chosen mode's fields are on the next one. That is not
 * decoration: measured against the viewport Calamares gives a view module — 710x536, the 900x600
 * branding window less the 190px sidebar and the 64px navigation bar — the one-page version of
 * this page wanted 595px in domain mode with nothing filled in and nothing expanded, so it
 * scrolled before anybody had typed anything, and the local administrator was the half below the
 * fold. Split in two it is 255px for the choice and 331px for the domain fields, and 481px in the
 * worst state anyone can reach: Advanced open, a failed domain check and three validation errors
 * at once. Nothing scrolls.
 *
 * `accounts.step` is held in C++ rather than here, because AccountsViewStep has to answer
 * isAtBeginning() and isAtEnd() with it — that is what makes the window's Back and Next move
 * between these two screens instead of leaving the page (see AccountsViewStep.cpp). The `Change`
 * button below is a second, visible way to do what Back already does.
 */

// Delegates in the Repeater below reach modeGroup, an id in this file's scope. Without this
// pragma that works by a lookup Qt deprecated: component scopes leak into their creation
// context, and qmllint says so. Bound gives delegates properly bound scope, which is also
// what makes `required property var modelData` the right way to receive the model row.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Item {
    id: root

    // ONE array, read twice: the chooser draws a row per entry, and the second screen's header
    // reads the chosen entry back out of it. The alternative — a title in the chooser and the
    // same title again in the header — is two strings that have to be kept saying the same thing.
    //
    // `mode` is the ONLY numeric enumerator in this file, and it appears once per choice, next to
    // the name it stands for. Everything downstream reads accounts.isLocalMode / isManagedMode /
    // isDomainMode instead, so renumbering AccountsConfig::Mode cannot quietly change which form
    // is shown.
    readonly property var modes: [
        {
            mode: 1,  // AccountsConfig.Local
            offered: accounts.localOffered,
            icon: "user-identity",
            title: qsTr("Local accounts only"),
            subtitle: qsTr("One account, on this computer. Nothing is sent anywhere."),
            needs: qsTr("Works with no network. More accounts can be added afterwards.")
        },
        {
            mode: 2,  // AccountsConfig.Managed
            offered: accounts.managedOffered,
            icon: "group",
            title: qsTr("Managed system"),
            subtitle: qsTr("Accounts come from your organisation, and whoever runs it can change them from anywhere."),
            needs: qsTr("Needs a network connection and an enrolment code now, before the disk is written.")
        },
        {
            mode: 3,  // AccountsConfig.Domain
            offered: accounts.domainOffered,
            icon: "network-server",
            title: qsTr("Join an enterprise domain"),
            subtitle: qsTr("Accounts come from Active Directory, with one local administrator kept as the way back in."),
            needs: qsTr("Needs the domain name and an account allowed to join computers to it.")
        }
    ]
    readonly property var chosen: root.modes.find(function (m) { return m.mode === accounts.mode }) || null

    // Calamares' window paints nothing behind this widget, so the page paints its own ground.
    Rectangle {
        anchors.fill: parent
        color: Kirigami.Theme.backgroundColor
    }

    // The mode buttons' exclusivity lives HERE rather than in a binding on each button's
    // `checked`. A QQC2 button sets `checked` imperatively when clicked, which breaks any binding
    // on it; the group is therefore the source of truth for the UI, and AccountsConfig.mode
    // mirrors it through onToggled. Nothing else in this file or in C++ writes `mode`.
    QQC2.ButtonGroup {
        id: modeGroup
    }

    QQC2.ScrollView {
        id: scroll
        anchors.fill: parent
        // Binding the content's width to availableWidth rather than to the page's own is what
        // keeps a long label from forcing a horizontal scrollbar: availableWidth already has the
        // vertical scrollbar's width taken off, so the content reflows instead of being pushed
        // under it if the page ever does grow tall enough to need one.
        contentWidth: availableWidth
        clip: true

        // THE MARGIN IS THE CONTENT'S, NOT ScrollView.padding. This read `padding:
        // Kirigami.Units.largeSpacing` and did nothing at all: qqc2-desktop-style's ScrollView
        // binds topPadding, leftPadding, rightPadding and bottomPadding individually (its
        // ScrollView.qml, to make room for the frame and the scrollbars), and an assignment to
        // the grouped `padding` property loses to those bindings. Nothing else supplies one
        // either — ViewManager applies widgetMargins only when the step's widget has a layout
        // (ViewManager.cpp:145) and AccountsViewStep::widget() returns a bare QQuickWidget — so
        // the page sat flush against the window edge, which is what rendering it showed.
        Item {
            id: sheet

            readonly property int margin: Kirigami.Units.largeSpacing

            width: scroll.availableWidth
            implicitHeight: column.implicitHeight + 2 * margin

            ColumnLayout {
                id: column

                x: sheet.margin
                y: sheet.margin
                width: sheet.width - 2 * sheet.margin
                spacing: Kirigami.Units.largeSpacing

                // ======== screen one: the choice ========================================
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: accounts.onChooser
                    spacing: Kirigami.Units.largeSpacing

                    Kirigami.Heading {
                        Layout.fillWidth: true
                        level: 2
                        wrapMode: Text.WordWrap
                        text: qsTr("How should people sign in to this computer?")
                    }

                    QQC2.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        opacity: 0.75
                        text: qsTr("This is the one choice on this page that cannot be changed later without reinstalling. Everything else follows from it.")
                    }

                    Repeater {
                        model: root.modes

                        // Selecting does NOT advance. Next does. A radio button that navigates is
                        // a radio button that punishes a mis-click by throwing away the screen
                        // you were reading, and the three options are meant to be compared with
                        // one of them selected.
                        //
                        // RadioButton with a hand-built contentItem and background, NOT
                        // RadioDelegate, because which SIDE the indicator is drawn on is a style
                        // decision and this page cannot afford to inherit it. Read off the three
                        // styles on the medium: RadioDelegate puts the indicator at
                        // `x: horizontalPadding` in qqc2-desktop-style (left) but at
                        // `x: width - width - rightPadding` in Qt's own Basic and Fusion (right —
                        // at the far end of a row whose text is on the left), and Fusion also
                        // paints every delegate's background with palette.base, an opaque white
                        // slab per row. RadioButton is the control whose indicator all three put
                        // at leftPadding, which is where a bullet belongs when what follows it is
                        // an icon and three lines of text.
                        delegate: QQC2.RadioButton {
                            id: choice

                            required property var modelData

                            Layout.fillWidth: true
                            visible: choice.modelData.offered
                            hoverEnabled: true
                            // Roomier than the style's own delegate padding, because this tinted
                            // box is a click target holding three lines, and the height is there:
                            // the chooser measures 255px of a 536px viewport.
                            padding: Kirigami.Units.largeSpacing
                            QQC2.ButtonGroup.group: modeGroup
                            onToggled: if (checked) { accounts.mode = choice.modelData.mode }

                            // `text` IS SET even though the contentItem below draws the title
                            // itself and no style draws `text` outside a contentItem, because the
                            // indicator's x asks about it: Basic and Fusion read
                            // `control.text ? leftPadding : leftPadding + (availableWidth - width) / 2`,
                            // so an empty text parks the bullet in the middle of the row — which
                            // is what rendering it under those styles showed. (The desktop style
                            // asks `contentItem.width > 0` instead and is left either way.) It is
                            // also the accessible name; the subtitle has to be given separately.
                            text: choice.modelData.title
                            Accessible.description: choice.modelData.subtitle

                            // The row's own ground: transparent unless it is hovered, focused or
                            // chosen, so the page's background shows through instead of a slab.
                            // The chosen row is tinted as well as bulleted, because on a screen
                            // whose whole purpose is one decision, the decision should be visible
                            // from across the room.
                            background: Rectangle {
                                radius: Kirigami.Units.cornerRadius
                                color: choice.checked
                                    ? Qt.alpha( Kirigami.Theme.highlightColor, 0.15 )
                                    : ( choice.hovered ? Qt.alpha( Kirigami.Theme.hoverColor, 0.25 )
                                                       : "transparent" )
                                border.width: choice.checked || choice.visualFocus ? 1 : 0
                                border.color: choice.visualFocus ? Kirigami.Theme.focusColor
                                                                 : Kirigami.Theme.highlightColor
                            }

                            // Kirigami's RadioSubtitleDelegate is the near-miss this replaces: it
                            // elides its subtitle instead of wrapping it, and there is a third
                            // line here. `needs` is what this choice will ask of you before the
                            // install can continue — the sentence somebody wants BEFORE choosing,
                            // not after.
                            contentItem: RowLayout {
                                spacing: Kirigami.Units.largeSpacing

                                // The indicator's footprint. Every style draws the indicator at
                                // the control's leftPadding and leaves room for it by padding the
                                // label it also supplies — a label this replaces, so the room has
                                // to be made here or the bullet lands on top of the icon.
                                Item {
                                    implicitWidth: choice.indicator ? choice.indicator.width : 0
                                    implicitHeight: 1
                                }

                                Kirigami.Icon {
                                    source: choice.modelData.icon
                                    implicitWidth: Kirigami.Units.iconSizes.large
                                    implicitHeight: Kirigami.Units.iconSizes.large
                                    Layout.alignment: Qt.AlignVCenter
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 0

                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: choice.modelData.title
                                        font.bold: true
                                        wrapMode: Text.WordWrap
                                    }

                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        text: choice.modelData.subtitle
                                        wrapMode: Text.WordWrap
                                        opacity: 0.7
                                    }

                                    QQC2.Label {
                                        Layout.fillWidth: true
                                        Layout.topMargin: Kirigami.Units.smallSpacing
                                        text: choice.modelData.needs
                                        wrapMode: Text.WordWrap
                                        opacity: 0.55
                                        font: Kirigami.Theme.smallFont
                                    }
                                }
                            }
                        }
                    }
                }

                // ======== screen two: the fields ========================================
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: accounts.onFields
                    spacing: Kirigami.Units.largeSpacing

                    // The header says which choice these fields belong to, because on this screen
                    // the choice itself is off-screen. `Change` does what the window's Back does;
                    // it is here because Back is a button in the far corner of the window and
                    // this is where somebody is looking when they realise they picked wrong.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing

                        Kirigami.Icon {
                            source: root.chosen ? root.chosen.icon : ""
                            implicitWidth: Kirigami.Units.iconSizes.medium
                            implicitHeight: Kirigami.Units.iconSizes.medium
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0

                            Kirigami.Heading {
                                Layout.fillWidth: true
                                level: 2
                                wrapMode: Text.WordWrap
                                text: root.chosen ? root.chosen.title : ""
                            }

                            QQC2.Label {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                opacity: 0.7
                                font: Kirigami.Theme.smallFont
                                text: root.chosen ? root.chosen.subtitle : ""
                            }
                        }

                        QQC2.Button {
                            text: qsTr("Change")
                            icon.name: "go-previous"
                            onClicked: accounts.goToChooser()
                        }
                    }

                    Kirigami.Separator {
                        Layout.fillWidth: true
                    }

                    // Each form is `visible` on the mode and nothing else. There is no "shown but
                    // disabled" state anywhere on this page: a field that does not apply is not
                    // drawn, which is the difference between this page and the
                    // checkbox-with-greyed-out-fields it replaces.
                    LocalForm {
                        Layout.fillWidth: true
                        visible: accounts.isLocalMode
                    }

                    ManagedForm {
                        Layout.fillWidth: true
                        visible: accounts.isManagedMode
                    }

                    DomainForm {
                        Layout.fillWidth: true
                        visible: accounts.isDomainMode
                    }
                }
            }
        }
    }
}
