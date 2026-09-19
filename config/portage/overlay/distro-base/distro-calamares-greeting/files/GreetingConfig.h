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
 * a one-sentence verdict, and showed an EMPTY bordered box when there were none — which is
 * indistinguishable from a box that has not finished checking. plan/28 answered that by listing
 * every check with its own status; plan/30 §2 answered it again, better, by listing the failures
 * and warnings and removing the panel entirely when there are none. See the long note above
 * UnsatisfiedRequirements below for why the first answer did not survive contact with the screen.
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
#include <QSortFilterProxyModel>
#include <QString>

class QAbstractItemModel;

/*! Calamares' requirements model with the passing checks taken out (plan/30 §2).
 *
 *  WHY THE PAGE SHOWS FEWER ROWS THAN IT USED TO, and it is a reversal of plan/28's reasoning
 *  rather than a bug fix. That plan replaced a vendored box which listed FAILURES only, on the
 *  grounds that "a box that shows nothing when all six pass cannot tell anybody that the network
 *  one is a note rather than a blocker". True — and the screen disagreed: on the machine the
 *  installer is normally run on, every check passes, and six green rows saying OK sat above the
 *  one sentence anybody reads. A page whose panel is always full is a page whose panel is never
 *  read, which is the state a warning has to appear out of.
 *
 *  So the panel is back to failures and warnings, and the difference from the vendored box is
 *  that it is now ABSENT rather than empty when there is nothing wrong — see hasProblems() and
 *  what the QML does with it.
 *
 *  A PROXY AND NOT A SNAPSHOT. RequirementsEntry holds its two sentences as FUNCTIONS, so that a
 *  language change re-reads them (upstream's reason, recorded in Requirements.h); a QVariantList
 *  built here would freeze whichever language was current when the checks ran. The proxy leaves
 *  the strings where they are and passes the model's own roles straight through, which is also
 *  why the QML delegate did not have to change a line.
 *
 *  NO invalidateFilter() ANYWHERE. The model is RESET rather than updated when a round of checks
 *  lands — addRequirementsList() calls beginResetModel() — and QSortFilterProxyModel re-filters
 *  on a source reset by itself. A hand-driven invalidate would be a second thing to keep in step
 *  with the first.
 */
class UnsatisfiedRequirements : public QSortFilterProxyModel
{
    Q_OBJECT

public:
    using QSortFilterProxyModel::QSortFilterProxyModel;

protected:
    bool filterAcceptsRow( int row, const QModelIndex& parent ) const override;
};

class GreetingConfig : public QObject
{
    Q_OBJECT

    /*! Calamares' own requirements model, every row of it. Nothing on the page binds this any
     *  more — `problems` is what the panel lists — and it is kept because it is the honest
     *  answer to "what did the checker find", and because `satisfiedMandatory` is read off it
     *  by the verdict line. */
    Q_PROPERTY( QAbstractItemModel* requirements READ requirementsModelForQml CONSTANT )

    /*! The same model with the passing checks filtered out (plan/30 §2) — what the panel lists.
     *  CONSTANT like the one above: the proxy object never changes, only its contents. */
    Q_PROPERTY( QAbstractItemModel* problems READ problemsModelForQml CONSTANT )

    /*! Whether there is anything in `problems` at all. The panel's `visible` binds this, so on a
     *  machine that passes every check there is no panel — and the verdict, which is the only
     *  line that matters then, moves up into the space it was occupying.
     *
     *  NOT `!satisfiedMandatory`. A warning is not a blocker: the internet check is deliberately
     *  optional (greeting.conf says so at length), and a machine with no network has something to
     *  show in the panel and a verdict that still says it can install. */
    Q_PROPERTY( bool hasProblems READ hasProblems NOTIFY problemsChanged )

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

    /*! The filtered view of the same thing, typed for the Q_PROPERTY above. */
    QAbstractItemModel* problemsModelForQml() const;

    bool hasProblems() const;

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
    /*! The panel's `visible` re-reads on this. Emitted whenever the proxy's row count can have
     *  moved, which on a model that is reset wholesale means: whenever it was reset. */
    void problemsChanged();
    /*! Every tr()'d property above re-reads on this. Emitted from retranslate(), which the
     *  Retranslator runs on a language change — and which the model's own verdict signals also
     *  run, because warningMessage() depends on both. */
    void retranslated();

private:
    /*! Idempotent: the first round of checks to land flips it and nothing flips it back. */
    void markChecked();

    QString m_warningMessage;
    bool m_checked = false;
    /*! Owned, and created in the constructor whether or not there is a model to give it: a null
     *  `problems` would be a ListView with no model, which QML accepts in silence. It gets its
     *  source model in the same branch that connects everything else. */
    UnsatisfiedRequirements* m_problems;
};
