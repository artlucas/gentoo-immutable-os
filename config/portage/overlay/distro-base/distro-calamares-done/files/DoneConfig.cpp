/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "DoneConfig.h"

#include "Branding.h"
#include "ViewManager.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"
#include "utils/Variant.h"
#include "viewpages/ExecutionViewStep.h"
#include "viewpages/ViewStep.h"

#include <QProcess>

// ================================ DoneModel ==================================================

DoneModel::DoneModel( QObject* parent )
    : QAbstractListModel( parent )
{
}

void
DoneModel::setEntries( const QVector< Entry >& entries )
{
    beginResetModel();
    m_entries = entries;
    endResetModel();
}

int
DoneModel::rowCount( const QModelIndex& parent ) const
{
    return parent.isValid() ? 0 : static_cast< int >( m_entries.count() );
}

QVariant
DoneModel::data( const QModelIndex& index, int role ) const
{
    if ( !index.isValid() || index.row() < 0 || index.row() >= m_entries.count() )
    {
        return {};
    }
    const Entry& e = m_entries.at( index.row() );
    switch ( role )
    {
    case LabelRole:
        return e.label;
    case ValueRole:
        return e.value;
    default:
        return {};
    }
}

QHash< int, QByteArray >
DoneModel::roleNames() const
{
    return { { LabelRole, "label" }, { ValueRole, "value" } };
}

// ================================ DoneConfig =================================================

DoneConfig::DoneConfig( QObject* parent )
    : QObject( parent )
    , m_rows( new DoneModel( this ) )
{
    CALAMARES_RETRANSLATE_SLOT( &DoneConfig::retranslate );
}

void
DoneConfig::setConfigurationMap( const QVariantMap& configurationMap )
{
    // UPSTREAM'S KEYS AND UPSTREAM'S SPELLINGS, including the two aliases it accepts for each
    // user-choice mode — config/calamares/modules/done.conf is a rendered copy of what
    // finished.conf said, and a medium whose configuration silently meant something else would be
    // the worst possible outcome of replacing a module.
    const QString mode
        = Calamares::getString( configurationMap, QStringLiteral( "restartNowMode" ) ).toLower();
    if ( mode == QLatin1String( "never" ) )
    {
        m_mode = RestartMode::Never;
    }
    else if ( mode == QLatin1String( "always" ) )
    {
        m_mode = RestartMode::Always;
    }
    else if ( mode == QLatin1String( "user-checked" ) || mode == QLatin1String( "checked" ) )
    {
        m_mode = RestartMode::UserChecked;
    }
    else if ( mode == QLatin1String( "user-unchecked" ) || mode == QLatin1String( "unchecked" ) )
    {
        m_mode = RestartMode::UserUnchecked;
    }
    else
    {
        // NEVER, not "restart anyway". An unreadable key must not be able to reboot somebody's
        // machine, and the medium's own configuration is checked by stage 40 — so reaching this
        // branch means the file on disk is not the file this repo wrote.
        cWarning() << "done: restartNowMode is" << mode << "- not a mode this module knows, so"
                   << "the page will not offer to restart at all.";
        m_mode = RestartMode::Never;
    }

    m_restartCommand
        = Calamares::getString( configurationMap, QStringLiteral( "restartNowCommand" ) );
    if ( m_restartCommand.isEmpty() && m_mode != RestartMode::Never )
    {
        cWarning() << "done: restartNowMode is set but restartNowCommand is empty, so nothing"
                   << "would happen when the box is ticked. Treating it as 'never'.";
        m_mode = RestartMode::Never;
    }

    m_restartWanted = ( m_mode == RestartMode::Always || m_mode == RestartMode::UserChecked );
    emit restartWantedChanged( m_restartWanted );
}

QAbstractItemModel*
DoneConfig::rowsModel() const
{
    return m_rows;
}

void
DoneConfig::collect()
{
    QVector< DoneModel::Entry > entries;

    auto* views = Calamares::ViewManager::instance();
    if ( views )
    {
        for ( Calamares::ViewStep* step : views->viewSteps() )
        {
            // STOP AT THE EXEC PHASE. Everything before it is what was just installed; this page
            // and the summary page before it are after. The summary page runs the opposite rule
            // on the same loop, and both are one line — see DoneConfig.h.
            if ( qobject_cast< Calamares::ExecutionViewStep* >( step ) )
            {
                break;
            }
            const QString value = step->prettyStatus();
            if ( value.isEmpty() )
            {
                continue;
            }
            entries.append( { step->prettyName(), value } );
        }
    }

    m_rows->setEntries( entries );
}

void
DoneConfig::setRestartWanted( bool wanted )
{
    // The mode decides, not the caller: `always` and `never` are not the user's to change, and
    // the page does not draw a control for them either (restartOffered).
    if ( m_mode == RestartMode::Always )
    {
        wanted = true;
    }
    if ( m_mode == RestartMode::Never )
    {
        wanted = false;
    }
    if ( wanted == m_restartWanted )
    {
        return;
    }
    m_restartWanted = wanted;
    emit restartWantedChanged( m_restartWanted );
}

void
DoneConfig::doRestart()
{
    if ( m_mode == RestartMode::Never || !m_restartWanted || m_restartCommand.isEmpty() )
    {
        return;
    }
    cDebug() << "done: restarting with" << m_restartCommand;
    // /bin/sh -c, upstream's call exactly: restartNowCommand is a shell line in a configuration
    // file (`systemctl -i reboot`), not an argv, and splitting it here would be a second, subtly
    // different parser for a string this medium's own configuration writes.
    QProcess::execute( QStringLiteral( "/bin/sh" ), { QStringLiteral( "-c" ), m_restartCommand } );
}

QString
DoneConfig::pageTitle() const
{
    const auto* branding = Calamares::Branding::instance();
    return tr( "%1 is installed" ).arg( branding ? branding->productName() : QString() );
}

void
DoneConfig::retranslate()
{
    emit retranslated();
}

#include "moc_DoneConfig.cpp"
