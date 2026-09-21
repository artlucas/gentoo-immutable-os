/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The finished page's state (plan/28 §6).
 *
 * WHAT THIS REPLACES. Calamares' own `finished` module — a .ui file with a label, an icon and a
 * "Restart now" checkbox, drawn in Breeze at the end of ten pages that are not. What it keeps is
 * the only behaviour that module has: `restartNowMode` and `restartNowCommand` from the
 * configuration, and a restart fired on aboutToQuit if the box is ticked.
 *
 * THE TABLE IS NOT NEW WORDS. Every row is a preceding view step's prettyStatus() — the same
 * sentences the summary page showed before the erase, now as the record of what was done. That is
 * deliberate: a finished page with its own vocabulary is a page that can describe an install
 * differently from the page that proposed it, and those two screens are ten minutes apart.
 *
 * WHERE THIS DIFFERS FROM THE SUMMARY PAGE'S RULE. `review` clears its list at an exec step,
 * because a summary describes what is ABOUT to happen and anything before an exec has already
 * happened. This page is the opposite: it describes what DID happen, so it takes exactly the
 * steps before the exec phase and stops there.
 */
#pragma once

#include <QAbstractListModel>
#include <QObject>
#include <QString>
#include <QVector>

class DoneModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles
    {
        LabelRole = Qt::DisplayRole,
        ValueRole = Qt::UserRole + 1,
    };

    struct Entry
    {
        QString label;
        QString value;
    };

    explicit DoneModel( QObject* parent = nullptr );

    void setEntries( const QVector< Entry >& entries );

    int rowCount( const QModelIndex& parent = QModelIndex() ) const override;
    QVariant data( const QModelIndex& index, int role ) const override;
    QHash< int, QByteArray > roleNames() const override;

private:
    QVector< Entry > m_entries;
};

class DoneConfig : public QObject
{
    Q_OBJECT

public:
    /*! Upstream's four, by upstream's names, because this module reads upstream's configuration
     *  keys and a third spelling of "the user may choose, unticked" would help nobody. */
    enum class RestartMode
    {
        Never,
        UserUnchecked,
        UserChecked,
        Always,
    };

private:
    Q_PROPERTY( QAbstractItemModel* rows READ rowsModel CONSTANT )

    Q_PROPERTY( QString pageTitle READ pageTitle NOTIFY retranslated )
    Q_PROPERTY( QString pageLede READ pageLede NOTIFY retranslated )
    Q_PROPERTY( QString restartLabel READ restartLabel NOTIFY retranslated )
    Q_PROPERTY( QString mediumReminder READ mediumReminder NOTIFY retranslated )

    /*! Whether the page draws the checkbox at all. `never` and `always` are decisions the medium
     *  has already made, and a control that cannot change anything is worse than no control. */
    Q_PROPERTY( bool restartOffered READ restartOffered CONSTANT )
    Q_PROPERTY( bool restartWanted READ restartWanted WRITE setRestartWanted NOTIFY restartWantedChanged )

public:
    explicit DoneConfig( QObject* parent = nullptr );

    void setConfigurationMap( const QVariantMap& configurationMap );

    QAbstractItemModel* rowsModel() const;

    /*! Re-reads every step before the exec phase. Called from onActivate(). */
    void collect();

    /*! Runs the configured command if the mode allows it and the box is ticked. Wired to
     *  QApplication::aboutToQuit by the view step, which is upstream's arrangement and the only
     *  one that works: the window has to come down before the machine goes. */
    void doRestart();

    QString pageTitle() const;
    /*! ONE SENTENCE, AND IT USED TO BE TWO (plan/32 §1). The second one said that anything still
     *  downloading would finish after the restart — about `appsetup`, which has already run by
     *  the time this page is drawn and which does nothing at all on an offline install. It cost a
     *  wrapped line at 18px/1.5, and this page was 10px taller than its viewport. */
    QString pageLede() const { return tr( "Restart to sign in for the first time." ); }
    QString restartLabel() const { return tr( "Restart now" ); }
    QString mediumReminder() const
    {
        return tr( "Remove the installation medium before the computer starts again." );
    }

    bool restartOffered() const
    {
        return m_mode == RestartMode::UserUnchecked || m_mode == RestartMode::UserChecked;
    }
    bool restartWanted() const { return m_restartWanted; }
    void setRestartWanted( bool wanted );

public slots:
    void retranslate();

signals:
    void retranslated();
    void restartWantedChanged( bool wanted );

private:
    DoneModel* m_rows;
    RestartMode m_mode = RestartMode::Never;
    QString m_restartCommand;
    bool m_restartWanted = false;
};
