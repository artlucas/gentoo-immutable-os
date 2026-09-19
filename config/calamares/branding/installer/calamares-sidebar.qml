/* The installer's left sidebar — Calamares v3.4.2's own src/calamares/calamares-sidebar.qml,
   COPIED rather than invented, and since plan/28 repainted from the design system rather than
   from branding.desc's four style: keys. Keeping the copy close to upstream is the same bet the
   greeting module's vendored checker files made, and lost: when a future Calamares ships a
   different sidebar the diff that matters here is now a header and a drawing, not one anchor.

   Loaded BY FILENAME CONVENTION, named by nothing in branding.desc: CalamaresWindow asks for
   "calamares-sidebar.qml" through searchQmlFile(QmlSearch::Both), which looks in the branding
   component directory before the compiled-in stock copy — so this file replaces that one for
   this branding alone, and `sidebar: qml` in branding.desc is what asks for the QML flavour at
   all (the widget flavour's centred text is hard-coded in ProgressTreeDelegate.cpp and cannot
   be reached from branding).

   THE COLOURS COME FROM Theme.qml, WHICH IS IN THIS DIRECTORY AT BUILD TIME. The view modules
   compile the token object into their own .so as a resource; this panel is not a module and has
   no resource, so stage 40 stages config/calamares/qml/Theme.qml beside this file and QML's
   implicit local-directory import finds it. branding.desc's style: map is still correct and is
   still what the WIDGET flavours read — see the note above it.

   "About" and "Debug" below are qsTranslate() into a NAMED context, CalamaresSidebar, whose
   entries are hand-maintained in the branding .ts files — the language page's LanguageNames
   bargain, because the builder's lupdate is built without QML support (plan/25 §4) and cannot
   extract from this file no matter what function it calls. The branding translator is installed
   on the app, and qsTranslate consults it by (context, source), so the two buttons follow the
   catalogue (plan/27 §3).

   NOTHING IN CALAMARES RETRANSLATES THIS FILE, and that is why it once read English in a Japanese
   installer. CalamaresWindow builds this QML into a QQuickWidget and then wires no retranslation
   to it at all: a qsTranslate() binding re-evaluates only when its engine is told to, and the
   step names below re-read `display` only when the ViewManager model says dataChanged — which
   upstream emits nowhere, because the WIDGET sidebar flavour gets its fresh words from a repaint
   and never needed a signal. Both are now driven from the module that changes the language, in
   LanguageViewStep.cpp's retranslateWindowPanels() (plan/27 §3), which finds this panel by this
   filename. Renaming this file without renaming it there leaves the sidebar stale again.

   SPDX-FileCopyrightText: 2020 Adriaan de Groot <groot@kde.org>
   SPDX-FileCopyrightText: 2021 Anke Boersma <demm@kaosx.us>
   SPDX-License-Identifier: GPL-3.0-or-later
*/
import io.calamares.ui 1.0
import io.calamares.core 1.0

import QtQuick 2.3
import QtQuick.Layouts 1.3

Rectangle {
    id: sideBar;

    readonly property Theme ds: Theme {}

    color: ds.surfacePage;
    anchors.fill: parent;

    // The seam between the rail and the page, which the design system draws as a 1px border
    // rather than a change of tone: both surfaces are pale and the boundary has to be stated.
    Rectangle {
        anchors.right: parent.right;
        anchors.top: parent.top;
        anchors.bottom: parent.bottom;
        width: 1;
        color: ds.borderSubtle;
    }

    ColumnLayout {
        anchors.fill: parent;
        anchors.topMargin: ds.space6;
        anchors.bottomMargin: ds.space5;
        anchors.leftMargin: ds.space4;
        anchors.rightMargin: ds.space4;
        spacing: 0;

        // LEFT-ALIGNED AND LOCKUP-SHAPED, not a centred square. The image is logo.png, composed
        // by make-splash-assets.py from the same block as the boot splash and flattened onto this
        // panel's own ground, so it has no edge to see. `fillMode: PreserveAspectFit` with only a
        // height set is what lets a wordmark-shaped block stay wordmark-shaped.
        //
        // NOTHING HERE READS `height`, AND THAT IS THE WHOLE POINT. This Image is a ColumnLayout
        // child, so the LAYOUT owns its width and height — `height: 32` is a starting value the
        // layout immediately overwrites with one it computes from implicitHeight. An Image takes
        // its implicitHeight from sourceSize once sourceSize is set. So `sourceSize.height:
        // height * 2` said: my implicit height is twice my height. The layout then set the height
        // to the implicit height, the next pass doubled it again, and the sidebar grew by a factor
        // of two per layout pass until the window was 2.8 million pixels tall. The backing store's
        // QImage — width x height x 4, here 11.7 GB — failed to allocate, the flush that needed it
        // failed, the failure scheduled another repaint, and Calamares sat at 100% CPU having
        // logged "Window now visible" for a window nobody would ever see.
        //
        // The QML engine does not call that a binding loop and never will: the cycle runs through
        // QQuickLayout's C++ and not through the engine, so no warning is printed at any logging
        // level. What it looks like from the outside is an installer that does not start.
        //
        // The sizes below are a constant and a ratio of two constants. sourceSize fixes
        // implicitWidth and implicitHeight to the file's own aspect, and Layout.preferred* are
        // what a layout child is supposed to state, so there is no path back from the geometry the
        // layout assigns to the geometry this item asks for.
        Image {
            id: logo;

            Layout.leftMargin: ds.space2;
            Layout.bottomMargin: ds.space6;
            Layout.alignment: Qt.AlignLeft | Qt.AlignTop;
            Layout.preferredHeight: 32;
            Layout.preferredWidth: Math.round(32 * logo.implicitWidth / Math.max(1, logo.implicitHeight));
            fillMode: Image.PreserveAspectFit;
            source: "file:/" + Branding.imagePath(Branding.ProductLogo);
            sourceSize.height: 64;   // 2 x the drawn height, for a HiDPI panel — a CONSTANT
        }

        Repeater {
            model: ViewManager

            Rectangle {
                id: stepRow;

                required property int index;
                required property string display;

                readonly property bool current: stepRow.index === ViewManager.currentStepIndex;
                readonly property bool done: stepRow.index < ViewManager.currentStepIndex;

                Layout.fillWidth: true;
                Layout.bottomMargin: 1;
                height: 34;
                radius: ds.radiusMd;
                color: stepRow.current ? ds.accentWash : "transparent";

                RowLayout {
                    anchors.fill: parent;
                    anchors.leftMargin: ds.space2 + 2;
                    anchors.rightMargin: ds.space2 + 2;
                    spacing: ds.space3 - 1;

                    // The mark: a ring for the step you are on, a filled tick for the ones behind
                    // you, an empty outline for the ones ahead. It is the one part of the row that
                    // says WHERE you are without depending on the text being legible.
                    Rectangle {
                        Layout.alignment: Qt.AlignVCenter;
                        implicitWidth: 16;
                        implicitHeight: 16;
                        radius: width / 2;
                        color: stepRow.done ? ds.accent : "transparent";
                        border.width: 2;
                        border.color: stepRow.current || stepRow.done ? ds.accent : ds.borderDefault;

                        Text {
                            anchors.centerIn: parent;
                            visible: stepRow.done;
                            text: "✓";
                            color: ds.accentOn;
                            font.family: ds.fontSans;
                            font.pixelSize: 9;
                            font.weight: ds.weightBold;
                        }
                    }

                    // LEFT-ALIGNED, which is the one change this file originally existed for
                    // (plan/26 §5): ProgressTreeDelegate.cpp centres every step name with a
                    // hard-coded Qt::AlignHCenter that no branding file can reach, and this
                    // installer's steps read better from the left.
                    Text {
                        Layout.fillWidth: true;
                        verticalAlignment: Text.AlignVCenter;
                        elide: Text.ElideRight;
                        text: stepRow.display;
                        color: stepRow.current ? ds.textStrong
                                               : (stepRow.done ? ds.textBody : ds.textSubtle);
                        font.family: ds.fontSans;
                        font.pixelSize: ds.textSm;
                        font.weight: stepRow.current ? ds.weightSemibold : ds.weightRegular;
                    }
                }
            }
        }

        Item {
            Layout.fillHeight: true;
        }

        // THE TWO META BUTTONS, as the design system's `ghost` variant: no fill until hover, no
        // border, the label in the body colour. They used to be two accent-filled halves of a bar
        // across the foot of the rail, which read as the primary action on the screen.
        RowLayout {
            Layout.fillWidth: true;
            spacing: ds.space1;

            // ONE BUTTON, TWICE, and a component rather than two drawings since plan/30 gave
            // both of them a keyboard. They are real controls — About opens Calamares' own
            // dialog, Debug opens the module inspector — and until now neither could be reached
            // by anything but a mouse. That is not in the ask, which names the navigation bar;
            // it is fixed with it because leaving two controls off the chain while putting the
            // other nine on it is not a position anybody would defend out loud.
            //
            // THE LABELS STAY qsTranslate("CalamaresSidebar", …) AND STAY IN THIS FILE, which is
            // the one thing the refactor must not quietly change: LanguageViewStep.cpp's
            // retranslateWindowPanels() finds this panel BY FILENAME and re-runs its engine's
            // translation, and the context string is what the catalogue is keyed on. An inline
            // component does not move either.
            component MetaButton: Rectangle {
                id: metaButton;

                property string label;

                signal activated();

                implicitWidth: metaLabel.implicitWidth + 2 * ds.space3;
                implicitHeight: ds.controlHeightSm;
                radius: ds.radiusMd;
                color: metaHover.hovered ? ds.surfaceSunken : "transparent";

                activeFocusOnTab: true;

                Accessible.role: Accessible.Button;
                Accessible.name: metaButton.label;
                Accessible.onPressAction: metaButton.activated();

                Keys.onSpacePressed: metaButton.activated();
                Keys.onReturnPressed: metaButton.activated();
                Keys.onEnterPressed: metaButton.activated();

                MouseArea {
                    id: metaHover;

                    anchors.fill: parent;
                    cursorShape: Qt.PointingHandCursor;
                    hoverEnabled: true;
                    onClicked: metaButton.activated();
                }

                // The installer's one focus ring, at the offset every other control draws it.
                Rectangle {
                    anchors.fill: parent;
                    anchors.margins: -3;
                    visible: metaButton.activeFocus;
                    radius: ds.radiusMd + 3;
                    color: "transparent";
                    border.width: 3;
                    border.color: ds.mix(ds.accent, ds.surfacePage, 0.4);
                }

                Text {
                    id: metaLabel;

                    anchors.centerIn: parent;
                    text: metaButton.label;
                    color: ds.textBody;
                    font.family: ds.fontSans;
                    font.pixelSize: ds.textSm;
                    font.weight: ds.weightSemibold;
                }
            }

            MetaButton {
                label: qsTranslate("CalamaresSidebar", "About");
                onActivated: debug.about();
            }

            MetaButton {
                visible: debug.enabled;
                label: qsTranslate("CalamaresSidebar", "Debug");
                onActivated: debug.toggle();
            }

            Item {
                Layout.fillWidth: true;
            }
        }
    }
}
