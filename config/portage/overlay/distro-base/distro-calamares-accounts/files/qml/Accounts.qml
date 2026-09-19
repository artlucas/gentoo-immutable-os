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
 * the style's name, and that plugin is what initialises the icon ds, so under any other style
 * this page has no icons at all (plan/21 §1b, measured in a VM).
 *
 * No qsTr() in this file, and none anywhere in this module's QML (plan/27 §1): the builder's
 * lupdate is built without QML support, so a qsTr() here never reached the branding catalogue
 * and rendered English in every language. Every word is a tr()'d AccountsConfig property
 * instead, re-said on a language change through the ViewStep's engine retranslate. (And never
 * i18n() either — plan/19 §7.2 measured what that does with no KLocalizedContext on the engine:
 * a ReferenceError and an empty string. Calamares is a C++ host and could install one, at the
 * cost of a ki18n dependency this page has no other use for.)
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
 * between these two screens instead of leaving the page (see AccountsViewStep.cpp). Those two
 * buttons are the only way between the screens; the page draws no navigation of its own.
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
    // The words inside are AccountsConfig properties, not qsTr() calls: the builder's lupdate is
    // built without QML support, so a qsTr() here has never reached the branding catalogue
    // (plan/27 §1). The array keeps its shape — one array, read twice — only its string sources
    // moved.
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
            title: accounts.localModeTitle,
            subtitle: accounts.localModeSubtitle,
            needs: accounts.localModeNeeds
        },
        {
            mode: 2,  // AccountsConfig.Managed
            offered: accounts.managedOffered,
            icon: "group",
            title: accounts.managedModeTitle,
            subtitle: accounts.managedModeSubtitle,
            needs: accounts.managedModeNeeds
        },
        {
            mode: 3,  // AccountsConfig.Domain
            offered: accounts.domainOffered,
            icon: "network-server",
            title: accounts.domainModeTitle,
            subtitle: accounts.domainModeSubtitle,
            needs: accounts.domainModeNeeds
        }
    ]
    readonly property var chosen: root.modes.find(function (m) { return m.mode === accounts.mode }) || null

    // THE PAGE PAINTS THE DESIGN SYSTEM, NOT THE DESKTOP THEME (plan/28). Without this block
    // Kirigami resolves these out of Breeze and the page is whichever Plasma ds the live
    // session happens to run. It matters for the controls this page does not draw itself — the
    // scroll bar and the two dialogs; the rest reads `ds` directly.
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

    // ONE Theme FOR THE PAGE AND ITS THREE FORMS. Each form takes it as a property rather than
    // instantiating its own — not for the allocation, which is nothing, but so that there is
    // exactly one object to look at when a colour is wrong.
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

            // The design system's content padding: 36 down the page, 44 in from the sides. It is
            // asymmetric, so `margin` became two.
            readonly property int margin: ds.space8 + ds.space1
            readonly property int sideMargin: ds.space10 + ds.space1

            width: scroll.availableWidth
            implicitHeight: column.implicitHeight + 2 * margin

            ColumnLayout {
                id: column

                x: sheet.sideMargin
                y: sheet.margin
                width: Math.min(sheet.width - 2 * sheet.sideMargin, ds.contentMaxWidth)
                spacing: ds.space6

                // ======== screen one: the choice ========================================
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: accounts.onChooser
                    // The design system's card gutter. The heading and its lede are one block
                    // inside it, with the tighter gap of their own, so that the two sentences
                    // read as one unit and the cards below do not.
                    spacing: ds.space3

                    ColumnLayout {
                        Layout.fillWidth: true
                        Layout.bottomMargin: ds.space3
                        spacing: ds.space2

                        Text {
                            Layout.fillWidth: true
                            text: accounts.chooserHeading
                            color: ds.textStrong
                            wrapMode: Text.WordWrap
                            font.family: ds.fontDisplay
                            font.pixelSize: ds.textHeading
                            font.weight: ds.weightBold
                            font.letterSpacing: ds.tracking(ds.trackingTight, ds.textHeading)
                        }

                        Text {
                            Layout.fillWidth: true
                            text: accounts.chooserWarning
                            color: ds.textMuted
                            wrapMode: Text.WordWrap
                            font.family: ds.fontSans
                            font.pixelSize: ds.textMd
                            lineHeight: ds.leadingNormal
                            lineHeightMode: Text.ProportionalHeight
                        }
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
                            // The design system's card padding. This box is a click target
                            // holding three lines, and the height is there: the chooser measures
                            // 255px of a 536px viewport.
                            padding: ds.space5 - 2
                            QQC2.ButtonGroup.group: modeGroup
                            onToggled: if (checked) { accounts.mode = choice.modelData.mode }

                            HoverHandler {
                                id: choiceHover
                                cursorShape: Qt.PointingHandCursor
                            }

                            // `text` IS SET even though the contentItem below draws the title
                            // itself and no style draws `text` outside a contentItem. It used to
                            // be load-bearing for the indicator's x — Basic and Fusion park an
                            // empty-text bullet in the middle of the row — and since plan/28 the
                            // indicator is gone entirely, so what it is now is the accessible
                            // name. The subtitle still has to be given separately.
                            text: choice.modelData.title
                            Accessible.description: choice.modelData.subtitle

                            // THE CARD IS THE CONTROL (plan/28). background, indicator and
                            // contentItem are all replaced, so the whole card is the hit area,
                            // the keyboard target and the accessible object. The chosen card is
                            // washed as well as bulleted, because on a screen whose whole purpose
                            // is one decision, the decision should be visible from across the
                            // room — and the design favours a border over a fill for everything
                            // else, which is why hover moves the border and not the ground.
                            background: Rectangle {
                                radius: ds.radiusLg
                                color: choice.checked ? ds.accentWash : ds.surfaceCard
                                border.width: ds.borderWidth
                                border.color: choice.checked || choice.visualFocus
                                    ? ds.accent
                                    : (choiceHover.hovered ? ds.borderStrong : ds.borderSubtle)

                                Behavior on border.color {
                                    ColorAnimation { duration: ds.durationBase }
                                }

                                // The installer's one focus ring (plan/30 §1). A border colour cannot carry this
                                // state on its own here: a chosen card is ALREADY accent-bordered when it is
                                // chosen, which is exactly the one a keyboard user is standing on.
                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: -3
                                    visible: choice.visualFocus
                                    radius: ds.radiusLg + 3
                                    color: "transparent"
                                    border.width: 3
                                    border.color: ds.mix(ds.accent, ds.surfaceCard, 0.4)
                                }
                            }

                            // Drawn inside contentItem below, at the design system's 20px with a
                            // 2px ring, rather than left where the style puts it.
                            indicator: null

                            // Kirigami's RadioSubtitleDelegate is the near-miss this replaces: it
                            // elides its subtitle instead of wrapping it, and there is a third
                            // line here. `needs` is what this choice will ask of you before the
                            // install can continue — the sentence somebody wants BEFORE choosing,
                            // not after.
                            // Kirigami's RadioSubtitleDelegate is the near-miss this replaces: it
                            // elides its subtitle instead of wrapping it, and there is a third
                            // line here. `needs` is what this choice will ask of you before the
                            // install can continue — the sentence somebody wants BEFORE choosing,
                            // not after.
                            contentItem: RowLayout {
                                spacing: ds.space3

                                Rectangle {
                                    Layout.alignment: Qt.AlignTop
                                    Layout.topMargin: 2
                                    implicitWidth: 20
                                    implicitHeight: 20
                                    radius: width / 2
                                    color: "transparent"
                                    border.width: ds.borderWidthStrong
                                    border.color: choice.checked ? ds.accent : ds.borderStrong

                                    Rectangle {
                                        anchors.centerIn: parent
                                        width: 10
                                        height: width
                                        radius: width / 2
                                        visible: choice.checked
                                        color: ds.accent
                                    }
                                }

                                Kirigami.Icon {
                                    source: choice.modelData.icon
                                    implicitWidth: 24
                                    implicitHeight: 24
                                    Layout.alignment: Qt.AlignTop
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 5

                                    Text {
                                        Layout.fillWidth: true
                                        text: choice.modelData.title
                                        color: ds.textStrong
                                        wrapMode: Text.WordWrap
                                        font.family: ds.fontSans
                                        font.pixelSize: ds.textBase
                                        font.weight: ds.weightSemibold
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: choice.modelData.subtitle
                                        color: ds.textMuted
                                        wrapMode: Text.WordWrap
                                        font.family: ds.fontSans
                                        font.pixelSize: ds.textSm
                                        lineHeight: ds.leadingSnug
                                        lineHeightMode: Text.ProportionalHeight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        Layout.topMargin: ds.space1
                                        text: choice.modelData.needs
                                        color: ds.textSubtle
                                        wrapMode: Text.WordWrap
                                        font.family: ds.fontSans
                                        font.pixelSize: ds.textXs
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
                    spacing: ds.space6

                    // The header says which choice these fields belong to, because on this screen
                    // the choice itself is off-screen. It is a label, not a control: the window's
                    // own Back is the one way back to the chooser, so there is exactly one thing
                    // to press and no second button that has to be kept doing the same thing.
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: ds.space2

                        Text {
                            Layout.fillWidth: true
                            text: root.chosen ? root.chosen.title : ""
                            color: ds.textStrong
                            wrapMode: Text.WordWrap
                            font.family: ds.fontDisplay
                            font.pixelSize: ds.textHeading
                            font.weight: ds.weightBold
                            font.letterSpacing: ds.tracking(ds.trackingTight, ds.textHeading)
                        }

                        Text {
                            Layout.fillWidth: true
                            text: root.chosen ? root.chosen.subtitle : ""
                            color: ds.textMuted
                            wrapMode: Text.WordWrap
                            font.family: ds.fontSans
                            font.pixelSize: ds.textMd
                            lineHeight: ds.leadingNormal
                            lineHeightMode: Text.ProportionalHeight
                        }
                    }

                    // Each form is `visible` on the mode and nothing else. There is no "shown but
                    // disabled" state anywhere on this page: a field that does not apply is not
                    // drawn, which is the difference between this page and the
                    // checkbox-with-greyed-out-fields it replaces.
                    LocalForm {
                        Layout.fillWidth: true
                        visible: accounts.isLocalMode
                        ds: root.ds
                    }

                    ManagedForm {
                        Layout.fillWidth: true
                        visible: accounts.isManagedMode
                        ds: root.ds
                    }

                    DomainForm {
                        Layout.fillWidth: true
                        visible: accounts.isDomainMode
                        ds: root.ds
                    }
                }
            }
        }
    }

    // ---- the question the window's Next asks on the fields screen (plan/26 §3) ----------------
    //
    // The disk page's confirmation, worn one screen later: while the password is complete but
    // failing libpwquality, AccountsViewStep::isAtEnd() is false, so ViewManager::next() calls
    // the step's next() instead of advancing — which is requestPasswordConfirmation(), the
    // signal the Connections below listens for. "Use anyway" settles the password and the view
    // step completes the advance; the answer is withdrawn by the next edit of either password
    // field, never by leaving the page — a chosen password is a decision, an erase is an event.
    //
    // At the root rather than in either form because both of them collect this password: local
    // for its own account, domain for the failsafe administrator.
    Kirigami.PromptDialog {
        id: weakPasswordDialog

        title: accounts.weakPasswordDialogTitle
        // libpwquality's own reason — the same sentence the field already shows in red, because
        // one policy should have one message (plan/21 §2). Every string in this dialog is a C++
        // tr() property now, so the whole question follows the catalogue (plan/27 §1); the
        // fallback line covers a message libpwquality declined to give.
        subtitle: accounts.passwordMessage.length > 0
                      ? accounts.passwordMessage
                      : accounts.weakPasswordFallback
        standardButtons: Kirigami.Dialog.NoButton
        customFooterActions: [
            Kirigami.Action {
                icon.name: "dialog-cancel"
                text: accounts.cancelLabel
                onTriggered: weakPasswordDialog.close()
            },
            Kirigami.Action {
                icon.name: "data-warning"
                text: accounts.useAnywayLabel
                onTriggered: {
                    weakPasswordDialog.close();
                    accounts.acceptWeakPassword();
                }
            }
        ]

        Connections {
            target: accounts
            function onPasswordConfirmationRequested() {
                weakPasswordDialog.open();
            }
        }
    }
}
