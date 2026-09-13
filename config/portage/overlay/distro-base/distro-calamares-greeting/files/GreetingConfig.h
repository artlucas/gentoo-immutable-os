/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * What the greeting page's requirements box asks for (plan/23 §2).
 *
 * THE SHAPE OF THIS CLASS IS NOT OURS TO CHOOSE. checker/ResultsListWidget.cpp is vendored from
 * Calamares verbatim, and it calls exactly three things on the object it is handed —
 * warningMessage(), unsatisfiedRequirements() and requirementsModel() — and connects to one
 * signal, warningMessageChanged(). Everything below is those four and nothing else. The page's own
 * strings live in GreetingPage, where a QWidget's tr() belongs.
 */
#pragma once

// A REAL INCLUDE AND NOT A FORWARD DECLARATION, because the vendored files reach through this
// header for it: upstream's Config.h includes modulesystem/RequirementsModel.h, and
// checker/CheckerContainer.cpp calls model.data(index, RequirementsModel::Satisfied) with no
// include of its own. Declaring the class here instead would mean editing two vendored files, which
// is exactly what plan/23 §2 is trying not to do.
#include "modulesystem/RequirementsModel.h"

#include <QObject>
#include <QString>

class QAbstractItemModel;
class QSortFilterProxyModel;

class GreetingConfig : public QObject
{
    Q_OBJECT

public:
    explicit GreetingConfig( QObject* parent = nullptr );

    /*! The sentence above the list of failures. TWO STATES, NOT UPSTREAM'S FOUR.
     *
     *  Upstream distinguishes "cannot continue" from "can continue, but some features might be
     *  disabled", and that second sentence would be a lie here: `internet` is checked and
     *  deliberately NOT required, because this medium carries its own payload and an offline
     *  install is a first-class path (greeting.conf says so at length). Nothing is disabled by
     *  installing without a network. So the verdict is the one the old QML page gave — this
     *  computer can or cannot install this product — and the coloured rows underneath are what
     *  say which item is a blocker and which is a note. */
    QString warningMessage() const { return m_warningMessage; }

    /*! Calamares' own model, shared by every module that contributes a requirement. Null before
     *  the ModuleManager exists, which is why every caller here checks. */
    Calamares::RequirementsModel* requirementsModel() const;

    /*! The same model with the satisfied rows filtered out — the box lists failures only. Built on
     *  first use, because requirementsModel() is not available when this object is constructed. */
    QAbstractItemModel* unsatisfiedRequirements() const;

public slots:
    /*! Recomputes warningMessage(). Wired to BOTH the Retranslator and the requirements model:
     *  the sentence changes when the language changes AND when a five-second re-check turns a
     *  failure into a pass, and the box's QLabel is only ever updated by the signal below. */
    void retranslate();

signals:
    void warningMessageChanged( QString message );

private:
    QString m_warningMessage;
    QSortFilterProxyModel* m_filtermodel;
};
