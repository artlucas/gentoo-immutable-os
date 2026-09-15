/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "DiskModel.h"

#include "Branding.h"

#include <QLocale>

DiskModel::DiskModel( QObject* parent )
    : QAbstractListModel( parent )
{
}

QString
DiskModel::formatSize( qint64 bytes )
{
    // SI, and the greeting page's disk row agrees since plan/24 §3. The unit is the one printed
    // on the disk, because the user's job on this page is to recognise their own hardware in a
    // list, and what they have to compare it against is a label on a box.
    return QLocale().formattedDataSize( bytes, 1, QLocale::DataSizeSIFormat );
}

QString
DiskModel::productName()
{
    const auto* branding = Calamares::Branding::instance();
    return branding ? branding->string( Calamares::Branding::ProductName ) : QStringLiteral( "this system" );
}

void
DiskModel::setEntries( const QVector< Entry >& entries )
{
    beginResetModel();
    m_entries = entries;
    endResetModel();
}

int
DiskModel::rowCount( const QModelIndex& parent ) const
{
    return parent.isValid() ? 0 : static_cast< int >( m_entries.count() );
}

QVariant
DiskModel::data( const QModelIndex& index, int role ) const
{
    if ( !index.isValid() || index.row() < 0 || index.row() >= m_entries.count() )
    {
        return {};
    }
    const Entry& e = m_entries.at( index.row() );
    switch ( role )
    {
    case TitleRole:
        return e.title;
    case NodeRole:
        return e.node;
    case SizeTextRole:
        return formatSize( e.bytes );
    case ContentsRole:
        // THE SECOND LINE IS THE REASON WHENEVER THERE IS ONE. A greyed row that went on
        // describing its partitions would say nothing about why it is greyed — and "why will it
        // not let me pick this disk" is exactly what this page has to answer without being asked.
        switch ( e.block )
        {
        case Block::LiveMedium:
            return tr( "%1 is running from this disk" ).arg( productName() );
        case Block::TooSmall:
            // The minimum is not repeated here. It is in the sentence under the heading, and the
            // disk's own size is already in this row's size column: the comparison is on screen.
            return tr( "Too small for an installation" );
        case Block::ReadOnly:
            return tr( "This disk is write-protected" );
        case Block::None:
            break;
        }
        return e.contents.isEmpty() ? tr( "Contents unknown" ) : e.contents;
    case BlockedRole:
        return e.block != Block::None;
    case RemovableRole:
        return e.removable;
    default:
        return {};
    }
}

QHash< int, QByteArray >
DiskModel::roleNames() const
{
    return { { TitleRole, "title" },      { NodeRole, "node" },       { SizeTextRole, "sizeText" },
             { ContentsRole, "contents" }, { BlockedRole, "blocked" }, { RemovableRole, "removable" } };
}

void
DiskModel::retranslated()
{
    if ( m_entries.isEmpty() )
    {
        return;
    }
    // ContentsRole and SizeTextRole are the two that are built rather than stored: one of them is
    // a sentence and the other goes through QLocale, whose decimal separator is the language's.
    emit dataChanged( index( 0 ), index( static_cast< int >( m_entries.count() ) - 1 ),
                      { ContentsRole, SizeTextRole } );
}

bool
DiskModel::isInstallable( int row ) const
{
    return row >= 0 && row < m_entries.count() && m_entries.at( row ).block == Block::None;
}

int
DiskModel::installableCount() const
{
    int n = 0;
    for ( const Entry& e : m_entries )
    {
        if ( e.block == Block::None )
        {
            ++n;
        }
    }
    return n;
}

#include "moc_DiskModel.cpp"
