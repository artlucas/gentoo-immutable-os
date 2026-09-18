/* The installer's navigation bar — Calamares v3.4.2's own src/calamares/calamares-navigation.qml,
   COPIED rather than invented, with its three stock Buttons redrawn from the design system
   (plan/28). Upstream's file is titled "Sample of QML navigation"; the sample's layout is kept
   and its controls are not.

   WHY THIS FILE EXISTS AT ALL. `navigation: widget` was the answer until plan/28, on the grounds
   that the widget bar "was never the problem" — the sidebar was, because it centred every step
   name. It is the problem now: a widget bar draws Breeze's buttons in Breeze's metrics, along the
   bottom of nine pages that draw the design system's, and the seam is the last thing a user sees
   on every screen.

   Loaded BY FILENAME CONVENTION, exactly as the sidebar is: CalamaresWindow asks for
   "calamares-navigation.qml" through searchQmlFile(QmlSearch::Both), which looks in the branding
   component directory before the compiled-in stock copy. `navigation: qml` in branding.desc is
   what asks for the QML flavour at all.

   THE COLOURS COME FROM Theme.qml, WHICH IS IN THIS DIRECTORY AT BUILD TIME — stage 40 stages
   config/calamares/qml/Theme.qml beside this file, and QML's implicit local-directory import
   finds it. See the sidebar's header for why that is not a resource like the view modules'.

   NOTHING IN CALAMARES RETRANSLATES THIS FILE, the sidebar's finding applied to its second panel:
   ViewManager.backLabel and friends are Q_PROPERTYs with NOTIFY signals, so THOSE re-read on
   their own — but a qsTranslate() binding re-evaluates only when its engine is told to, and
   nothing tells it. This file uses no qsTranslate() for exactly that reason: every word on it is
   ViewManager's, which retranslates itself. If a string of our own is ever added here, it has to
   join the sidebar in LanguageViewStep.cpp's retranslateWindowPanels().

   SPDX-FileCopyrightText: 2020 Adriaan de Groot <groot@kde.org>
   SPDX-License-Identifier: GPL-3.0-or-later
*/
import io.calamares.ui 1.0
import io.calamares.core 1.0

import QtQuick 2.3
import QtQuick.Layouts 1.3

Rectangle {
    id: navigationBar;

    readonly property Theme ds: Theme {}

    // The design system's inset ground under the page's card, with a hairline above it — the same
    // relationship the sidebar has with the page, and the same 1px seam.
    color: ds.surfacePage;
    height: 72;

    Rectangle {
        anchors.left: parent.left;
        anchors.right: parent.right;
        anchors.top: parent.top;
        height: 1;
        color: ds.borderSubtle;
    }

    // ONE BUTTON, THREE VARIANTS, and it is a local component rather than the shared
    // config/calamares/qml/Button.qml for a reason worth stating: this panel is not a view module,
    // it has no Qt resource, and the shared file is staged into this directory only if something
    // here names it. It could be — but Button.qml takes a `ds` property and this panel's controls
    // also need ViewManager's enabled/visible plumbing, so the sample's own Buttons are replaced
    // in place instead. If a third panel ever needs one, that is the moment to share.
    component NavButton: Rectangle {
        id: button;

        property string label;
        property string variant: "primary";
        property bool active: true;

        signal clicked();

        implicitWidth: buttonText.implicitWidth + 2 * navigationBar.ds.space4;
        implicitHeight: navigationBar.ds.controlHeightMd;
        radius: navigationBar.ds.radiusMd;
        opacity: button.active ? 1 : 0.5;

        color: button.variant === "primary"
            ? (hoverArea.containsMouse && button.active ? navigationBar.ds.accentHover
                                                        : navigationBar.ds.accent)
            : (button.variant === "secondary"
                ? (hoverArea.containsMouse && button.active ? navigationBar.ds.surfaceSunken
                                                            : navigationBar.ds.surfaceCard)
                : (hoverArea.containsMouse && button.active ? navigationBar.ds.surfaceSunken
                                                            : "transparent"));
        border.width: button.variant === "secondary" ? navigationBar.ds.borderWidth : 0;
        border.color: navigationBar.ds.borderDefault;

        MouseArea {
            id: hoverArea;

            anchors.fill: parent;
            hoverEnabled: true;
            enabled: button.active;
            cursorShape: button.active ? Qt.PointingHandCursor : Qt.ArrowCursor;
            onClicked: button.clicked();
        }

        Text {
            id: buttonText;

            anchors.centerIn: parent;
            text: button.label;
            color: button.variant === "primary" ? navigationBar.ds.accentOn
                                                : (button.variant === "secondary"
                                                    ? navigationBar.ds.textStrong
                                                    : navigationBar.ds.textBody);
            font.family: navigationBar.ds.fontSans;
            font.pixelSize: navigationBar.ds.textBase;
            font.weight: navigationBar.ds.weightSemibold;
        }
    }

    // QUIT IS THE PRIMARY ACTION ON EXACTLY ONE SCREEN, and the last one is it. Calamares keeps
    // Back and Next visible on the finished page and disables both — there is nothing after it —
    // so the only live control in this bar is Quit, relabelled by the ViewManager ("Done", or
    // whatever the translation says). Drawn as a ghost button at the far left, beside two dead
    // buttons at the right, that reads as the least important thing on the screen instead of the
    // only thing left to press.
    //
    // So: when Next cannot be pressed and Quit can, Quit moves to the right end and takes the
    // primary fill. TWO INSTANCES rather than a reparenting, because a Layout child that changes
    // ends is a Layout that re-runs on every property change of ViewManager, and `visible` is
    // what a RowLayout already understands.
    readonly property bool quitIsPrimary:
        ViewManager.quitVisible && ViewManager.quitEnabled && !ViewManager.nextEnabled;

    /* EVERY LABEL IN THIS BAR IS A WIDGET LABEL, and a widget label carries a mnemonic.
       ViewManager hands out "&Back", "&Next", "&Cancel", "&Install now" — the ampersand marks the
       Alt- shortcut letter, QWidget eats it and draws an underline, and a QML Text has no such
       convention and draws the ampersand. The bar came up reading "&Cancel  &Back  &Next", which
       is what upstream's sample does too; upstream's sample is a sample.
       Qt's escape for a literal ampersand in a mnemonic string is "&&", so that has to survive as
       one "&" rather than being eaten with the rest — hence the placeholder rather than a single
       pass of replace(). No translation in config/calamares/branding/installer/lang uses one
       today, and this costs one line to be right if one ever does.
       NOT A CANDIDATE FOR retranslateWindowPanels(): these are ViewManager Q_PROPERTYs with NOTIFY
       signals, so the bindings re-run on a language change by themselves. See the header. */
    function plainLabel(s) {
        return s ? s.replace(/&&/g, "\u0001").replace(/&/g, "").replace(/\u0001/g, "&") : "";
    }

    RowLayout {
        id: buttonBar;

        anchors.fill: parent;
        anchors.topMargin: navigationBar.ds.space4;
        anchors.bottomMargin: navigationBar.ds.space4;
        anchors.leftMargin: navigationBar.ds.space6;
        anchors.rightMargin: navigationBar.ds.space6;
        spacing: navigationBar.ds.space3 - 2;

        // QUIT ON THE LEFT, AWAY FROM NEXT. Upstream's sample puts all three buttons at the right
        // end, which makes "leave without installing" the neighbour of "continue" — and on this
        // installer the button beside Next on the summary page writes to somebody's disk.
        NavButton {
            variant: "ghost";
            label: navigationBar.plainLabel(ViewManager.quitLabel);
            active: ViewManager.quitEnabled;
            visible: ViewManager.quitVisible && !navigationBar.quitIsPrimary;
            onClicked: ViewManager.quit();
        }

        Item {
            Layout.fillWidth: true;
        }

        NavButton {
            variant: "secondary";
            label: navigationBar.plainLabel(ViewManager.backLabel);
            active: ViewManager.backEnabled;
            visible: ViewManager.backAndNextVisible;
            onClicked: ViewManager.back();
        }

        NavButton {
            variant: "primary";
            label: navigationBar.plainLabel(ViewManager.nextLabel);
            active: ViewManager.nextEnabled;
            visible: ViewManager.backAndNextVisible && !navigationBar.quitIsPrimary;
            onClicked: ViewManager.next();
        }

        // The same action as the ghost button above, at the other end of the bar — see the note
        // on quitIsPrimary. Only one of the two is ever visible.
        NavButton {
            variant: "primary";
            label: navigationBar.plainLabel(ViewManager.quitLabel);
            active: true;
            visible: navigationBar.quitIsPrimary;
            onClicked: ViewManager.quit();
        }
    }
}
