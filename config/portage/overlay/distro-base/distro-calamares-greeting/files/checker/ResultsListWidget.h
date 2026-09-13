/*
 * VENDORED FROM CALAMARES 3.4.2, src/modules/welcome/checker/ResultsListWidget.h (plan/23 §2).
 *
 * These three classes are the stock welcome page's requirements box. They are not in libcalamaresui
 * and no header of theirs is installed, so a module that wants the box has to carry the source —
 * which is also why the class names, the layout and every translatable string below are left
 * exactly as upstream wrote them: the diff against a future Calamares release should be this
 * header and the edit named under it, and nothing else.
 *
 * THE EDIT, in full: `Config` (the stock welcome module's config class) is spelled
 * `GreetingConfig` here, because ours is the object that answers warningMessage(),
 * requirementsModel() and unsatisfiedRequirements(). Nothing else is changed.
 *
 * WHAT THIS BOX DOES THAT OUR OWN VERDICT GRID DID NOT, and it is the reason for vendoring rather
 * than re-drawing: it lists only the requirements that FAILED, and when every one of them passes
 * it deletes the list and puts the branding's productWelcome image in its place, expanding. A
 * healthy machine therefore reads as one sentence and a logo instead of six green ticks nobody
 * needed to check.
 */
/* === This file is part of Calamares - <https://calamares.io> ===
 *
 *   SPDX-FileCopyrightText: 2014-2015 Teo Mrnjavac <teo@kde.org>
 *   SPDX-FileCopyrightText: 2019-2020 Adriaan de Groot <groot@kde.org>
 *   SPDX-License-Identifier: GPL-3.0-or-later
 *
 *   Calamares is Free Software: see the License-Identifier above.
 *
 */

#ifndef CHECKER_RESULTSLISTWIDGET_H
#define CHECKER_RESULTSLISTWIDGET_H

#include "GreetingConfig.h"

#include <QWidget>

class CountdownWaitingWidget;

class QBoxLayout;
class QLabel;

class ResultsListWidget : public QWidget
{
    Q_OBJECT
public:
    explicit ResultsListWidget( GreetingConfig* config, QWidget* parent );

    /// @brief The model of requirements has finished a round of checking
    void requirementsComplete();

private:
    GreetingConfig* m_config = nullptr;

    // UI parts, which need updating when the model changes
    QLabel* m_explanation = nullptr;
    CountdownWaitingWidget* m_countdown = nullptr;
    // There is a central widget, which can be:
    // - a list widget showing failed requirements
    // - nullptr (when displaying a pretty label for language / splash purposes)
    // it is placed in the central layout.
    QWidget* m_centralWidget = nullptr;
    QBoxLayout* m_centralLayout = nullptr;
};

#endif  // CHECKER_RESULTSLISTWIDGET_H
