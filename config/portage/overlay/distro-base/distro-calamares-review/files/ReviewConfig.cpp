/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "ReviewConfig.h"

#include "Branding.h"
#include "GlobalStorage.h"
#include "JobQueue.h"
#include "ViewManager.h"
#include "utils/Retranslator.h"
#include "viewpages/ExecutionViewStep.h"
#include "viewpages/ViewStep.h"

// ================================ ReviewModel ================================================

ReviewModel::ReviewModel( QObject* parent )
    : QAbstractListModel( parent )
{
}

void
ReviewModel::setEntries( const QVector< Entry >& entries )
{
    beginResetModel();
    m_entries = entries;
    endResetModel();
}

int
ReviewModel::rowCount( const QModelIndex& parent ) const
{
    return parent.isValid() ? 0 : static_cast< int >( m_entries.count() );
}

QVariant
ReviewModel::data( const QModelIndex& index, int role ) const
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
ReviewModel::roleNames() const
{
    return { { LabelRole, "label" }, { ValueRole, "value" } };
}

// ================================ ReviewConfig ===============================================

ReviewConfig::ReviewConfig( QObject* parent )
    : QObject( parent )
    , m_rows( new ReviewModel( this ) )
{
    CALAMARES_RETRANSLATE_SLOT( &ReviewConfig::retranslate );
}

QAbstractItemModel*
ReviewConfig::rowsModel() const
{
    return m_rows;
}

void
ReviewConfig::collect( const Calamares::ViewStep* upToHere )
{
    QVector< ReviewModel::Entry > entries;

    auto* views = Calamares::ViewManager::instance();
    if ( views )
    {
        for ( Calamares::ViewStep* step : views->viewSteps() )
        {
            // UPSTREAM'S RULE, AND IT IS NOT AN OPTIMISATION. A summary describes the steps since
            // the last exec phase, so anything before one belongs to an install that has already
            // happened. This installer has exactly one exec phase and one summary, so the branch
            // never fires today — it is here because the day a second pair is added, a summary
            // that listed both would be describing work that is already on the disk.
            if ( qobject_cast< Calamares::ExecutionViewStep* >( step ) )
            {
                entries.clear();
                continue;
            }
            if ( step == upToHere )
            {
                break;
            }

            // A step with nothing to say is not a row. The stock page draws an empty heading for
            // one; a label/value table draws a label with a blank beside it, which reads as a
            // question that was not answered rather than as one that has no answer.
            const QString value = step->prettyStatus();
            if ( value.isEmpty() )
            {
                continue;
            }
            entries.append( { step->prettyName(), value } );
        }
    }

    auto* gs = Calamares::JobQueue::instance() ? Calamares::JobQueue::instance()->globalStorage()
                                              : nullptr;
    // plan/33 §8: the one piece of state this page keeps about ITSELF, re-read every collect()
    // exactly like the rows are, so it cannot go stale independently of them.
    m_keeping = gs && gs->value( QStringLiteral( "diskKeepData" ) ).toBool();

    m_rows->setEntries( entries );
    emit rowsChanged();
}

QString
ReviewConfig::eraseTitle() const
{
    // GlobalStorage's `diskDevice` — NOT `device`, which NOTHING HAS EVER PUBLISHED. This read
    // that key, silently, since the page was written: gs->value() on a missing key answers an
    // empty QVariant, device.isEmpty() was always true, and every install this installer has
    // ever run showed "This erases the selected disk completely" regardless of which disk was
    // chosen. DiskConfig::publish() writes `diskDevice`; read here rather than reached for
    // through the disk module, because a summary that #included another view module's header
    // would be a link-time dependency between two plugins that Calamares loads separately.
    auto* gs = Calamares::JobQueue::instance() ? Calamares::JobQueue::instance()->globalStorage()
                                              : nullptr;
    const QString device = gs ? gs->value( QStringLiteral( "diskDevice" ) ).toString() : QString();
    const QString diskName = device.isEmpty() ? unknownDiskText() : device;
    if ( m_keeping )
    {
        const auto* branding = Calamares::Branding::instance();
        const QString product
            = branding ? branding->string( Calamares::Branding::ProductName ) : tr( "this system" );
        return tr( "This reinstalls %1 on %2" ).arg( product, diskName );
    }
    return tr( "This erases %1 completely" ).arg( diskName );
}

QString
ReviewConfig::eraseBody() const
{
    if ( m_keeping )
    {
        return tr( "The system is replaced with a fresh copy. The accounts, files, apps and "
                   "settings on that drive are kept, and other drives are left alone." );
    }
    return tr( "Every partition, file and operating system on that drive will be removed. "
               "Other drives are left alone." );
}

void
ReviewConfig::retranslate()
{
    emit retranslated();
    // The rows are OTHER steps' words, so they have to be re-asked rather than re-read: each of
    // those steps has its own retranslate, and nothing says which order they run in. Emitting
    // this re-evaluates eraseTitle() too, whose disk name is not translated but whose sentence is.
    emit rowsChanged();
}

#include "moc_ReviewConfig.cpp"
