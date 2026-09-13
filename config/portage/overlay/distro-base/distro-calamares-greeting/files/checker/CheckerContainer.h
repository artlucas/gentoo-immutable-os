/*
 * VENDORED FROM CALAMARES 3.4.2, src/modules/welcome/checker/CheckerContainer.h (plan/23 §2).
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
 */
/* === This file is part of Calamares - <https://calamares.io> ===
 *
 *   SPDX-FileCopyrightText: 2014-2017 Teo Mrnjavac <teo@kde.org>
 *   SPDX-FileCopyrightText: 2017 Adriaan de Groot <groot@kde.org>
 *   SPDX-FileCopyrightText: 2017 Gabriel Craciunescu <crazy@frugalware.org>
 *   SPDX-License-Identifier: GPL-3.0-or-later
 *
 *   Calamares is Free Software: see the License-Identifier above.
 *
 */

/* Based on code extracted from RequirementsChecker.cpp */

#ifndef CHECKERCONTAINER_H
#define CHECKERCONTAINER_H

#include "GreetingConfig.h"

#include <QWidget>

class ResultsListWidget;
class WaitingWidget;

/**
 * A widget that collects requirements results; until the results are
 * all in, displays a spinner / waiting widget. Then it switches to
 * a (list) diplay of the results, plus some explanation of the
 * overall state of the entire list of results.
 */

class CheckerContainer : public QWidget
{
    Q_OBJECT
public:
    explicit CheckerContainer( GreetingConfig* config, QWidget* parent = nullptr );
    ~CheckerContainer() override;

    bool verdict() const;

public slots:
    /** @brief All the requirements are complete, switch to list view */
    void requirementsComplete( bool );

    void requirementsProgress( const QString& message );

protected:
    WaitingWidget* m_waitingWidget;
    ResultsListWidget* m_checkerWidget;

    bool m_verdict;

private:
    GreetingConfig* m_config = nullptr;
};

#endif
