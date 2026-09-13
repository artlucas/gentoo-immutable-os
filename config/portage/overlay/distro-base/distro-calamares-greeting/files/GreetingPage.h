/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The greeting: who you are about to install, what is about to happen to the disk, and whether
 * this machine can do it (plan/23 §1).
 *
 * A QWidget, AND THE ONLY ONE OF OUR THREE PAGES THAT IS. The language and accounts pages are QML
 * in a QQuickWidget because they draw controls Qt Widgets has no good answer for — a two-line
 * delegate per row, a three-way card chooser. This page draws two labels and then hands the rest
 * of the window to checker/CheckerContainer, which is upstream's widget: there is no QML version
 * of it, it is not in libcalamaresui, and reimplementing its behaviour in Kirigami would be a
 * second copy of a thing whose whole value is that it is the same box every Calamares installer
 * shows. Widgets are also what locale, keyboard, partition, summary and finished already are, so
 * this page matches five of the installer's eight rather than two.
 *
 * THERE IS NO LOGO IN THE HEADER, deliberately. ResultsListWidget puts the branding's
 * productWelcome image into the box, expanding, the moment every requirement passes — so on the
 * healthy path this page is a sentence and a logo, and a second logo above it would be the
 * "logo sized to fill whatever space is left over" that plan/22 opened by complaining about.
 */
#pragma once

#include <QWidget>

class CheckerContainer;
class GreetingConfig;

class QLabel;

class GreetingPage : public QWidget
{
    Q_OBJECT

public:
    explicit GreetingPage( GreetingConfig* config, QWidget* parent = nullptr );

private slots:
    void retranslate();

private:
    GreetingConfig* m_config;
    QLabel* m_heading;
    QLabel* m_subtitle;
    QLabel* m_mainText;
    CheckerContainer* m_checker;
};
