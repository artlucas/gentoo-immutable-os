/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The greeting page (plan/23 §1, rewritten from QWidget to QML in plan/28).
 *
 * WHAT THIS REPLACED, AND WHY IT IS A DELETION RATHER THAN A PORT. The page was a QWidget with
 * three QLabels and `checker/CheckerContainer` — three files vendored verbatim from Calamares'
 * own welcome module, because "they are not in libcalamaresui and no header of theirs is
 * installed, so a module that wants the box has to carry the source" (plan/23 §2). What that
 * traded away was control of the box, and RequirementsModel IS an installed header — so a QML
 * ListView binds it directly and the vendored copies went with the widget.
 *
 * WHAT THE PANEL LISTS HAS NOW BEEN DECIDED TWICE, and the second answer is nearly the first.
 * plan/28 drew a row per check, on the reasoning that a box showing nothing when all six pass
 * cannot say which of them was a blocker and which a note. plan/30 §2 took that back: the machine
 * this installer normally runs on passes everything, so the panel was six green rows saying OK
 * above the one sentence anybody reads, and a panel that is always full is a panel that is never
 * read. It lists failures and warnings, and on a machine that has neither it is not there at all
 * — which is the part the vendored box never did, since an EMPTY bordered box is indistinguishable
 * from one that has not finished checking. The required/optional distinction survives, drawn on
 * the rows that have something to say.
 *
 * THE ROOT ITEM IS A PLAIN Item, for the reason every sibling page gives: this is loaded into a
 * QQuickWidget that Calamares parents into its own window, so an ApplicationWindow would be a
 * second window that never appears and a Kirigami page assumes a stack that is not there.
 *
 * No qsTr() in this file. The builder's lupdate is built without QML support (plan/27 §1), so a
 * qsTr() here would never reach the branding catalogue. Every word is a GreetingConfig property,
 * tr()'d in C++ — which is also why GreetingPage's strings and the two vendored widgets' strings
 * moved INTO GreetingConfig rather than merely moving file: a Qt context is a class name.
 *
 * `greeting` is the GreetingConfig context property.
 *
 * NOTHING HERE GATES Next. GreetingViewStep::isNextEnabled() reads the model's satisfiedMandatory
 * directly, and this page cannot disagree with it because it does not hold a copy.
 */
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.kirigami as Kirigami

Item {
    id: root

    // THE PAGE PAINTS THE DESIGN SYSTEM, NOT THE DESKTOP THEME (plan/28). Without this block
    // Kirigami resolves these out of Breeze and the page is whichever Plasma theme the live
    // session happens to run. It matters for the controls this page does not draw itself — the
    // scroll bar; the rest reads `ds` directly.
    //
    // `inherit: false` AND NOTHING ELSE IS THE SWITCH. There is no Kirigami.Theme.Custom colour
    // set — the ColorSet enum is View/Window/Button/Selection/Tooltip/Complementary/Header — and
    // naming one would have evaluated to undefined and been assigned silently.
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

    // The page OWNS the token object rather than merely holding an id for it, and that is what
    // makes `ds: root.ds` say what it means where a child needs one. Passed down as `ds: ds` it
    // would resolve the right-hand side in the CHILD's scope, where the child's own `ds` property
    // shadows this one — a binding loop, an undefined theme, and a page drawn in whatever a null
    // token object evaluates to.
    readonly property Theme ds: Theme {}

    // Calamares' window paints nothing behind this widget, so the page paints its own ground.
    Rectangle {
        anchors.fill: parent
        color: ds.surfaceCard
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: ds.pageMarginV      // 28/44 — see Theme.qml's note
        anchors.bottomMargin: ds.pageMarginV
        anchors.leftMargin: ds.pageMarginH
        anchors.rightMargin: ds.pageMarginH
        spacing: ds.space6 + 2

        ColumnLayout {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            spacing: ds.space2

            Text {
                Layout.fillWidth: true
                text: greeting.pageTitle
                color: ds.textStrong
                wrapMode: Text.WordWrap
                font.family: ds.fontDisplay
                font.pixelSize: ds.textHeading
                font.weight: ds.weightBold
                font.letterSpacing: ds.tracking(ds.trackingTight, ds.textHeading)
            }

            Text {
                Layout.fillWidth: true
                text: greeting.pageLede
                color: ds.textMuted
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textMd
                lineHeight: ds.leadingNormal
                lineHeightMode: Text.ProportionalHeight
            }
        }

        // ---- what is wrong, if anything ----------------------------------------------------
        // A BORDERED LIST WITH HAIRLINES BETWEEN THE ROWS, which is the design system's shape for
        // a table of facts: one border round the whole thing rather than a card per row, because
        // these rows are not choices and nothing here is clickable.
        //
        // FAILURES AND WARNINGS ONLY, AND NO PANEL AT ALL WHEN THERE ARE NONE (plan/30 §2). This
        // is a reversal of plan/28, which listed every check on the reasoning that a box showing
        // nothing when all six pass cannot say which of them was optional. True, and the screen
        // disagreed: the machine this installer normally runs on passes everything, so the panel
        // was six green rows saying OK above the one sentence anybody reads. The distinction
        // between a blocker and a note is still drawn — on the rows that HAVE something to say.
        //
        // TWO REASONS TO BE VISIBLE, and the first one is not "there is a problem": before the
        // first round of checks lands there is nothing to filter, and "nothing is wrong" is not
        // yet true. That is the spinner's state and it keeps the panel.
        Rectangle {
            id: checksPanel

            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.maximumWidth: ds.contentMaxWidth
            // AS TALL AS WHAT IS IN IT, AND NO TALLER. The panel filled the page's whole spare
            // height when it listed all six checks, which was right for six rows and is wrong for
            // the one or two this now shows: a single failing row at the top of a 300px box, with
            // the verdict that concludes it pinned to the bottom of the screen. Capped rather
            // than hugged, so that a machine failing everything still scrolls instead of pushing
            // the verdict off the page.
            //
            // No binding loop: contentHeight depends on the delegates' heights, which depend on
            // the view's WIDTH (the text wraps), and width does not depend on this.
            Layout.maximumHeight: greeting.checked
                ? checks.contentHeight + 2 * ds.borderWidth
                : spinner.implicitHeight + 2 * ds.space8
            visible: !greeting.checked || greeting.hasProblems
            radius: ds.radiusLg
            color: ds.surfaceCard
            border.width: ds.borderWidth
            border.color: ds.borderSubtle
            clip: true

            // Before the first round lands there is nothing to list, and an empty bordered box
            // would read as "no checks" rather than "not yet". The three dots are the design
            // system's only looped animation, at its own timing.
            RowLayout {
                id: spinner

                anchors.centerIn: parent
                visible: !greeting.checked
                spacing: ds.space3

                Row {
                    spacing: 4

                    Repeater {
                        model: 3

                        Rectangle {
                            required property int index

                            width: 6
                            height: 6
                            radius: 3
                            color: ds.accent

                            SequentialAnimation on opacity {
                                running: !greeting.checked
                                loops: Animation.Infinite

                                PauseAnimation { duration: index * 160 }
                                NumberAnimation { to: 1.0; duration: 160 }
                                NumberAnimation { to: 0.25; duration: 160 }
                                PauseAnimation { duration: (2 - index) * 160 }
                            }
                        }
                    }
                }

                Text {
                    text: greeting.gatheringText
                    color: ds.textMuted
                    font.family: ds.fontSans
                    font.pixelSize: ds.textSm
                }
            }

            QQC2.ScrollView {
                anchors.fill: parent
                visible: greeting.checked
                contentWidth: availableWidth
                clip: true

                ListView {
                    id: checks

                    // The FILTERED model, not `greeting.requirements` — see the panel's note
                    // above and the long one on UnsatisfiedRequirements in GreetingConfig.h. The
                    // delegate did not change a line: the proxy passes the model's own roles
                    // straight through.
                    model: greeting.problems
                    // Nothing on this page is selectable, so the view must not pretend otherwise:
                    // a highlight here would be a control the user cannot use.
                    interactive: true
                    currentIndex: -1
                    spacing: 0

                    delegate: Item {
                        id: row

                        required property string name
                        required property string details
                        required property string negatedText
                        required property bool satisfied
                        required property bool mandatory

                        width: checks.width
                        implicitHeight: rowBody.implicitHeight + 2 * (ds.space3 + 3)

                        // The hairline between rows, on the row rather than between them: a
                        // Separator item per gap is a second list to keep in step with the first.
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 1
                            visible: row.y + row.height < checks.contentHeight
                            color: ds.divider
                        }

                        RowLayout {
                            id: rowBody

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: ds.space5 - 2
                            anchors.rightMargin: ds.space5 - 2
                            spacing: ds.space3 + 2

                            // The status mark. A tick when the check passed; otherwise the
                            // tone says whether it is a blocker or a note, which is the
                            // distinction the old failures-only box drew in colour alone.
                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                implicitWidth: 22
                                implicitHeight: 22
                                radius: width / 2
                                color: row.satisfied
                                    ? ds.statusSuccessBg
                                    : (row.mandatory ? ds.statusDangerBg : ds.statusWarningBg)

                                Text {
                                    anchors.centerIn: parent
                                    text: row.satisfied ? "✓" : "!"
                                    color: row.satisfied
                                        ? ds.statusSuccess
                                        : (row.mandatory ? ds.statusDanger : ds.statusWarning)
                                    font.family: ds.fontSans
                                    font.pixelSize: ds.textXs
                                    font.weight: ds.weightBold
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                Text {
                                    Layout.fillWidth: true
                                    text: row.name
                                    color: ds.textStrong
                                    elide: Text.ElideRight
                                    font.family: ds.fontSans
                                    font.pixelSize: ds.textSm
                                    font.weight: ds.weightMedium
                                }

                                // `details` when the check passed, `negatedText` when it did not
                                // — the model carries both, and the second is the sentence that
                                // says what is wrong rather than what was measured.
                                Text {
                                    Layout.fillWidth: true
                                    text: row.satisfied ? row.details : row.negatedText
                                    color: ds.textMuted
                                    wrapMode: Text.WordWrap
                                    font.family: ds.fontSans
                                    font.pixelSize: ds.textXs
                                }
                            }

                            // The badge. Passed rows say so; failed rows say whether they are in
                            // greeting.conf's `required:` list, because that is the difference
                            // between "this install cannot proceed" and "this is worth knowing".
                            Rectangle {
                                Layout.alignment: Qt.AlignVCenter
                                implicitWidth: badge.implicitWidth + 2 * ds.space2
                                implicitHeight: 20
                                radius: ds.radiusSm
                                color: row.satisfied
                                    ? ds.statusSuccessBg
                                    : (row.mandatory ? ds.statusDangerBg : ds.statusWarningBg)

                                Text {
                                    id: badge

                                    anchors.centerIn: parent
                                    text: row.satisfied
                                        ? greeting.passedLabel
                                        : (row.mandatory ? greeting.requiredLabel
                                                         : greeting.optionalLabel)
                                    color: row.satisfied
                                        ? ds.statusSuccess
                                        : (row.mandatory ? ds.statusDanger : ds.statusWarning)
                                    font.family: ds.fontSans
                                    font.pixelSize: ds.textXs
                                    font.weight: ds.weightSemibold
                                }
                            }
                        }
                    }
                }
            }
        }

        // ---- the verdict -----------------------------------------------------------------
        // Below the list rather than above it, which is where the vendored box put it: the list
        // is the evidence and this is the conclusion, and on a machine that passes everything the
        // conclusion is the only line anybody needs to read — which since plan/30 it literally
        // is, because the panel above is gone and this has moved up into its place. A ColumnLayout
        // skips a child whose `visible` is false, so nothing had to be written to make that
        // happen; what DID have to be written is the filler below, since the height the panel was
        // filling has to go somewhere and this line must not be stretched down the page.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.maximumWidth: ds.contentMaxWidth
            visible: greeting.checked
            spacing: ds.space1

            // THE VERDICT WEARS THE SAME MARK ITS EVIDENCE DOES. Every row in the list above
            // carries a 22px status chip, and the sentence that concludes them carried none — so
            // the one line on this page that says whether the install can happen at all was the
            // only status on it drawn as plain text. It is the same chip, at the same size, in
            // the same two tones: the success tint and a tick when the machine passes, the
            // danger tint and an exclamation when it does not.
            //
            // BOTH VERDICTS, not just the good one. A tick that appears on success and leaves
            // nothing behind on failure makes the failure case read as "not checked yet" — which
            // is exactly the state the spinner above means, and the one this line replaces.
            //
            // The tick is a glyph and not a Canvas, unlike Done.qml's: at 22px this is the row
            // chip, and the row chip has set its mark in the sans face since the page was
            // written. Done.qml draws its at 34px inside a 72px disc, where a font's tick is a
            // different shape at a size where the difference shows.
            RowLayout {
                Layout.fillWidth: true
                spacing: ds.space3 - 2

                Rectangle {
                    Layout.alignment: Qt.AlignTop
                    implicitWidth: 22
                    implicitHeight: 22
                    radius: width / 2
                    color: checksSatisfied.satisfied ? ds.statusSuccessBg : ds.statusDangerBg

                    Text {
                        anchors.centerIn: parent
                        text: checksSatisfied.satisfied ? "✓" : "!"
                        color: checksSatisfied.satisfied ? ds.statusSuccess : ds.statusDanger
                        font.family: ds.fontSans
                        font.pixelSize: ds.textXs
                        font.weight: ds.weightBold
                    }
                }

                Text {
                    Layout.fillWidth: true
                    // The chip is 22 and the line is 14: centred on the text's first line rather
                    // than on the paragraph, so a verdict that ever wraps keeps its mark beside
                    // the words it marks instead of drifting down the block.
                    Layout.topMargin: Math.round((22 - contentHeight) / 2)
                    text: greeting.warningMessage
                    color: ds.textStrong
                    wrapMode: Text.WordWrap
                    font.family: ds.fontSans
                    font.pixelSize: ds.textSm
                    font.weight: ds.weightSemibold
                }
            }

            // The checker re-arms a five-second timer for as long as a mandatory requirement is
            // unmet, so "attach a bigger disk and the page clears itself" is real behaviour and
            // this is the line that says so. Only while something is still blocking.
            Text {
                Layout.fillWidth: true
                visible: greeting.warningMessage.length > 0 && !checksSatisfied.satisfied
                text: greeting.recheckText
                color: ds.textMuted
                wrapMode: Text.WordWrap
                font.family: ds.fontSans
                font.pixelSize: ds.textXs
            }

            QtObject {
                id: checksSatisfied

                // The model's own verdict, read through the property the page already binds
                // rather than recomputed from the rows: two answers to one question is how a page
                // comes to disagree with the Next button beside it.
                readonly property bool satisfied:
                    greeting.requirements ? greeting.requirements.satisfiedMandatory : false
            }
        }

        // THE SPARE HEIGHT, wherever it comes from. When there is no panel that is all of it and
        // the verdict sits just under the lede, which is where the panel's top edge was; when
        // there is one, it is whatever the panel's cap above did not take. Unconditional, because
        // both cases want the same thing: nothing on this page stretched down the screen.
        Item {
            Layout.fillHeight: true
        }
    }
}
