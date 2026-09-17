/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * What the greeting page's requirements box asks for (plan/23 §2).
 *
 * THE SHAPE OF THIS CLASS WAS NOT OURS TO CHOOSE, AND NOW IT IS. Until plan/28 it was dictated by
 * checker/ResultsListWidget.cpp, three files vendored from Calamares verbatim that called exactly
 * warningMessage(), unsatisfiedRequirements() and requirementsModel() and connected to
 * warningMessageChanged(). The page is QML now and those three files are gone — RequirementsModel
 * is an INSTALLED header (libcalamares/modulesystem/RequirementsModel.h), so a QML ListView can
 * bind the model directly and there is nothing left for a vendored widget to do. plan/23 §2 took
 * the vendoring as the lesser evil against "a fourth drawing of a widget every Calamares installer
 * already shows"; the design system asked for a different drawing anyway, so the copy stopped
 * earning its keep.
 *
 * WHAT CHANGED ON SCREEN, and it is more than paint. The vendored box listed FAILURES only, above
 * a one-sentence verdict. This page lists every check with its own status, which is what the
 * handoff draws and what the checks were always for: greeting.conf checks six things and requires
 * three, and a box that shows nothing when all six pass cannot tell anybody that the network one
 * is a note rather than a blocker.
 *
 * Every string the page shows is a tr()'d property here, because the builder's lupdate is built
 * without QML support (plan/27 §1) and a qsTr() in the QML would reach no catalogue. That is also
 * why GreetingPage's two strings and the two vendored widgets' strings moved into this file
 * rather than merely moving house: a Qt context IS a class name, so the catalogue entries had to
 * move with them (plan/23's own finding, check 5 in scripts/lib/check-translations.py).
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

class GreetingConfig : public QObject
{
    Q_OBJECT

    /*! Calamares' own requirements model, every row of it. The page draws a row per check with
     *  its own status, so it binds THIS and not the failures-only proxy the vendored box used. */
    Q_PROPERTY( QAbstractItemModel* requirements READ requirementsModelForQml CONSTANT )

    /*! The verdict above the list. */
    Q_PROPERTY( QString warningMessage READ warningMessage NOTIFY warningMessageChanged )

    /*! False until the first round of checks has finished, which is a state the page has to draw
     *  rather than guess at: `satisfiedMandatory` is false before anything has been measured, and
     *  a page that rendered that as "this computer cannot install" would be wrong for the second
     *  the scan takes. */
    Q_PROPERTY( bool checked READ checked NOTIFY checkedChanged )

    /*! The heading and its opening sentence. The heading is the product's own versioned name,
     *  from branding, and is NOT translatable — it is a name and a version number. */
    Q_PROPERTY( QString pageTitle READ pageTitle NOTIFY retranslated )
    Q_PROPERTY( QString pageLede READ pageLede NOTIFY retranslated )

    /*! What the page says while the first round is still running, and what it says underneath
     *  once a mandatory check has failed — the checker re-arms a five-second timer for as long as
     *  one is unmet, so "attach a bigger disk and the page clears itself" needs saying. Both came
     *  from the vendored widgets, with their catalogue entries. */
    Q_PROPERTY( QString gatheringText READ gatheringText NOTIFY retranslated )
    Q_PROPERTY( QString recheckText READ recheckText NOTIFY retranslated )

    /*! The three words a row's status chip can carry. `Required` and `Optional` are the
     *  distinction the vendored box drew in colour alone and this one says out loud: six checks
     *  run and three of them block. */
    Q_PROPERTY( QString passedLabel READ passedLabel NOTIFY retranslated )
    Q_PROPERTY( QString requiredLabel READ requiredLabel NOTIFY retranslated )
    Q_PROPERTY( QString optionalLabel READ optionalLabel NOTIFY retranslated )

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

    /*! The same pointer as requirementsModel(), typed for the Q_PROPERTY above. QML needs a
     *  QAbstractItemModel*, and a Q_PROPERTY cannot READ through a covariant return. */
    QAbstractItemModel* requirementsModelForQml() const;

    bool checked() const { return m_checked; }

    QString pageTitle() const;
    QString pageLede() const;
    QString gatheringText() const { return tr( "Gathering system information…" ); }
    QString recheckText() const { return tr( "Checking requirements again in a few seconds…" ); }
    QString passedLabel() const { return tr( "OK" ); }
    QString requiredLabel() const { return tr( "Required" ); }
    QString optionalLabel() const { return tr( "Optional" ); }

public slots:
    /*! Recomputes warningMessage(). Wired to BOTH the Retranslator and the requirements model:
     *  the sentence changes when the language changes AND when a five-second re-check turns a
     *  failure into a pass, and the box's QLabel is only ever updated by the signal below. */
    void retranslate();

signals:
    void warningMessageChanged( QString message );
    void checkedChanged( bool value );
    /*! Every tr()'d property above re-reads on this. Emitted from retranslate(), which the
     *  Retranslator runs on a language change — and which the model's own verdict signals also
     *  run, because warningMessage() depends on both. */
    void retranslated();

private:
    /*! Idempotent: the first round of checks to land flips it and nothing flips it back. */
    void markChecked();

    QString m_warningMessage;
    bool m_checked = false;
};
