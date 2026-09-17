/* The installer's left sidebar — Calamares v3.4.2's own src/calamares/calamares-sidebar.qml,
   COPIED rather than invented, with the ONE change this file exists for (plan/26 §5): the step
   names are left-aligned with a margin instead of centred. Keeping the copy close to upstream is
   the same bet the greeting module's vendored checker files make: when a future Calamares ships
   a different sidebar, the diff that matters here is a header and one anchor.

   Loaded BY FILENAME CONVENTION, named by nothing in branding.desc: CalamaresWindow asks for
   "calamares-sidebar.qml" through searchQmlFile(QmlSearch::Both), which looks in the branding
   component directory before the compiled-in stock copy — so this file replaces that one for
   this branding alone, and `sidebar: qml` in branding.desc is what asks for the QML flavour at
   all (the widget flavour's centred text is hard-coded in ProgressTreeDelegate.cpp and cannot
   be reached from branding).

   The colours come from branding.desc's style: map through Branding.styleString below — the
   same dark surface and teal current-step as the widget flavour had, so the change reads as
   alignment and nothing else.

   "About" and "Debug" below are qsTranslate() into a NAMED context, CalamaresSidebar, whose
   entries are hand-maintained in the branding .ts files — the language page's LanguageNames
   bargain, because the builder's lupdate is built without QML support (plan/25 §4) and cannot
   extract from this file no matter what function it calls. The branding translator is installed
   on the app, and qsTranslate consults it by (context, source), so the two buttons follow the
   catalogue (plan/27 §3). One limit remains, stated plainly: Calamares' own sidebar engine gets
   no engine-retranslate from our code, so a language changed mid-session leaves these two in the
   old language until restart — the step names do not share the problem, re-saying through the
   ViewManager model in C++ tr().

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
    color: Branding.styleString( Branding.SidebarBackground );
    anchors.fill: parent;

    ColumnLayout {
        anchors.fill: parent;
        spacing: 0;

        Image {
            Layout.topMargin: 12;
            Layout.bottomMargin: 12;
            Layout.alignment: Qt.AlignHCenter | Qt.AlignTop
            id: logo;
            width: 80;
            height: width;  // square
            source: "file:/" + Branding.imagePath(Branding.ProductLogo);
            sourceSize.width: width;
            sourceSize.height: height;
        }

        Repeater {
            model: ViewManager
            Rectangle {
                Layout.leftMargin: 6;
                Layout.rightMargin: 6;
                Layout.fillWidth: true;
                height: 35;
                radius: 6;
                color: Branding.styleString( index == ViewManager.currentStepIndex ? Branding.SidebarBackgroundCurrent : Branding.SidebarBackground );

                // THE ONE CHANGE (plan/26 §5): anchored left with a margin, not centred —
                // anchors.left + anchors.leftMargin instead of anchors.horizontalCenter, on the
                // same vertical centring the stock file uses. 12 within a row already inset 6
                // reads as moderate padding on a 190px sidebar.
                Text {
                    anchors.verticalCenter: parent.verticalCenter;
                    anchors.left: parent.left;
                    anchors.leftMargin: 12;
                    color: Branding.styleString( index == ViewManager.currentStepIndex ? Branding.SidebarTextCurrent : Branding.SidebarText );
                    text: display;
                }
            }
        }

        Item {
            Layout.fillHeight: true;
        }

        Rectangle {
            id: metaArea
            Layout.fillWidth: true;
            height: 35
            Layout.alignment: Qt.AlignHCenter | Qt.AlignBottom
            color: Branding.styleString( Branding.SidebarBackground );
            visible: true;

            Rectangle {
                id: aboutArea
                height: 35
                width: parent.width / 2;
                anchors.left: parent.left
                color: Branding.styleString( Branding.SidebarBackgroundCurrent );
                visible: true;

                MouseArea {
                    id: mouseAreaAbout
                    anchors.fill: parent;
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    Text {
                        anchors.verticalCenter: parent.verticalCenter;
                        anchors.horizontalCenter: parent.horizontalCenter;
                        x: parent.x + 4;
                        text: qsTranslate("CalamaresSidebar", "About")
                        color: Branding.styleString( Branding.SidebarTextCurrent );
                        font.pointSize : 9
                    }

                    onClicked: debug.about()
                }
            }

            Rectangle {
                id: debugArea
                height: 35
                width: parent.width / 2;
                anchors.right: parent.right
                color: Branding.styleString( Branding.SidebarBackgroundCurrent );
                visible: debug.enabled

                MouseArea {
                    id: mouseAreaDebug
                    anchors.fill: parent;
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: true
                    Text {
                        anchors.verticalCenter: parent.verticalCenter;
                        anchors.horizontalCenter: parent.horizontalCenter;
                        x: parent.x + 4;
                        text: qsTranslate("CalamaresSidebar", "Debug")
                        color: Branding.styleString( Branding.SidebarTextCurrent );
                        font.pointSize : 9
                    }

                    onClicked: debug.toggle()
                }
            }
        }
    }
}
