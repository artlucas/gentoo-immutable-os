/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "Requirements.h"

#include "GlobalStorage.h"
#include "JobQueue.h"
#include "network/Manager.h"
#include "utils/Gui.h"
#include "utils/Logger.h"
#include "utils/System.h"
#include "utils/Variant.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QGuiApplication>
#include <QLocale>
#include <QScreen>
#include <QStorageInfo>
#include <QUrl>

#include <functional>
#include <utility>  // std::as_const

#include <unistd.h>  // geteuid

static constexpr qint64 GiB = 1024LL * 1024LL * 1024LL;

/// @brief Human bytes, in the units disk tools show: "443.2 GiB", not "476 GB".
static QString
humanBytes( qint64 bytes )
{
    // IEC rather than SI, and the whole reason is the configuration file: requiredStorage is
    // written in GiB, so a page reporting "34.4 GB needed" for a config that says 32.0 would send
    // whoever set it looking for a bug that is not there.
    return QLocale().formattedDataSize( bytes, 1, QLocale::DataSizeIecFormat );
}

Requirements::Requirements( QObject* parent )
    : QObject( parent )
{
}

void
Requirements::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_toCheck = Calamares::getStringList( configurationMap, QStringLiteral( "check" ) );
    m_toRequire = Calamares::getStringList( configurationMap, QStringLiteral( "required" ) );
    m_requiredStorageGiB = Calamares::getDouble( configurationMap, QStringLiteral( "requiredStorage" ), 0.0 );
    m_requiredRamGiB = Calamares::getDouble( configurationMap, QStringLiteral( "requiredRam" ), 0.0 );

    // Loud, because both of these are numbers whose absence produces a page that says yes to
    // everything. Upstream defaults them to 3 GiB and 1 GiB and warns; defaulting to a value that
    // every machine satisfies is the same thing as not checking, so this refuses instead.
    if ( m_requiredStorageGiB <= 0.0 )
    {
        cWarning() << "greeting: requiredStorage is missing or zero — the disk check will be "
                      "skipped, which is what plan/22 §3a exists to stop happening.";
        m_toCheck.removeAll( QStringLiteral( "storage" ) );
        m_toRequire.removeAll( QStringLiteral( "storage" ) );
    }
    if ( m_requiredRamGiB <= 0.0 )
    {
        cWarning() << "greeting: requiredRam is missing or zero — the memory check will be skipped.";
        m_toCheck.removeAll( QStringLiteral( "ram" ) );
        m_toRequire.removeAll( QStringLiteral( "ram" ) );
    }

    for ( const auto& r : std::as_const( m_toRequire ) )
    {
        if ( !m_toCheck.contains( r ) )
        {
            cWarning() << "greeting: '" << r << "' is required but never checked.";
        }
    }

    // The URLs the internet check pings. Static on the Manager, exactly as GeneralRequirements
    // set them, so nothing else in Calamares that asks Network::Manager about connectivity gets a
    // different answer from this page.
    const QStringList urlStrings = Calamares::getStringList( configurationMap, QStringLiteral( "internetCheckUrl" ) );
    QVector< QUrl > urls;
    for ( const auto& s : urlStrings )
    {
        const QUrl url( s.trimmed() );
        if ( url.isValid() )
        {
            urls.append( url );
        }
        else
        {
            cWarning() << "greeting: internetCheckUrl entry is not a URL:" << s;
        }
    }
    if ( !urls.isEmpty() )
    {
        Calamares::Network::Manager::setCheckHasInternetUrl( urls );
    }
    else if ( m_toCheck.contains( QStringLiteral( "internet" ) ) )
    {
        cWarning() << "greeting: 'internet' is checked but internetCheckUrl names no valid URL.";
        m_toCheck.removeAll( QStringLiteral( "internet" ) );
        m_toRequire.removeAll( QStringLiteral( "internet" ) );
    }
}

qint64
Requirements::largestInstallableDiskB()
{
    // The disk this medium is running from, as a /sys/block name. QStorageInfo gives the device
    // node of whatever is mounted at '/' — "/dev/sda2", "/dev/nvme0n1p3" — and a partition of
    // disk D is always a directory INSIDE /sys/block/D, so the containment test needs no string
    // surgery on partition-number suffixes (which is where "nvme0n1p3" -> "nvme0n" goes wrong).
    const QString rootNode = QFileInfo( QString::fromUtf8( QStorageInfo::root().device() ) ).fileName();

    qint64 best = 0;
    const QDir sysBlock( QStringLiteral( "/sys/block" ) );
    const auto disks = sysBlock.entryList( QDir::Dirs | QDir::NoDotAndDotDot | QDir::NoSymLinks )
        + sysBlock.entryList( QDir::Dirs | QDir::NoDotAndDotDot | QDir::System );
    QStringList seen;
    for ( const QString& disk : disks )
    {
        if ( seen.contains( disk ) )
        {
            continue;
        }
        seen.append( disk );

        // Not disks: loopback, ramdisks, zram, optical, device-mapper and MD arrays. An installer
        // that offered to write the root image into /dev/zram0 would be a very short bug report.
        if ( disk.startsWith( QLatin1String( "loop" ) ) || disk.startsWith( QLatin1String( "ram" ) )
             || disk.startsWith( QLatin1String( "zram" ) ) || disk.startsWith( QLatin1String( "sr" ) )
             || disk.startsWith( QLatin1String( "dm-" ) ) || disk.startsWith( QLatin1String( "md" ) ) )
        {
            continue;
        }

        // The live medium itself, either as the whole disk or as the disk holding root's partition.
        if ( !rootNode.isEmpty()
             && ( rootNode == disk || QFileInfo::exists( QStringLiteral( "/sys/block/%1/%2" ).arg( disk, rootNode ) ) ) )
        {
            continue;
        }

        QFile sizeFile( QStringLiteral( "/sys/block/%1/size" ).arg( disk ) );
        if ( !sizeFile.open( QIODevice::ReadOnly | QIODevice::Text ) )
        {
            continue;
        }
        bool ok = false;
        // ALWAYS 512-byte units, whatever the drive's own sector size: /sys/block/*/size is
        // documented in 512-byte sectors and does not follow queue/logical_block_size. A 4Kn disk
        // reported through the logical size would read as eight times its real capacity.
        const qint64 sectors = QString::fromUtf8( sizeFile.readAll() ).trimmed().toLongLong( &ok );
        sizeFile.close();
        if ( !ok || sectors <= 0 )
        {
            continue;
        }
        best = qMax( best, sectors * 512LL );
    }
    return best;
}

bool
Requirements::batteryExists()
{
    const QDir supplies( QStringLiteral( "/sys/class/power_supply" ) );
    const auto entries = supplies.entryList( QDir::Dirs | QDir::NoDotAndDotDot | QDir::System );
    for ( const QString& e : entries )
    {
        QFile type( supplies.absoluteFilePath( e ) + QStringLiteral( "/type" ) );
        if ( type.open( QIODevice::ReadOnly | QIODevice::Text )
             && QString::fromUtf8( type.readAll() ).trimmed() == QLatin1String( "Battery" ) )
        {
            return true;
        }
    }
    return false;
}

bool
Requirements::onMainsPower()
{
    // SYSFS, NOT UPower, and that is a subtraction rather than an omission. Upstream asks
    // org.freedesktop.UPower for OnBattery over the system bus; UPower's own answer comes from
    // exactly these files, so the d-bus round trip buys nothing here and costs a dependency on a
    // daemon being up in a session that pkexec started with a scrubbed environment. One fewer
    // moving part in a check whose failure mode is a page that says the wrong thing quietly.
    const QDir supplies( QStringLiteral( "/sys/class/power_supply" ) );
    const auto entries = supplies.entryList( QDir::Dirs | QDir::NoDotAndDotDot | QDir::System );
    for ( const QString& e : entries )
    {
        QFile type( supplies.absoluteFilePath( e ) + QStringLiteral( "/type" ) );
        if ( !type.open( QIODevice::ReadOnly | QIODevice::Text ) )
        {
            continue;
        }
        const QString t = QString::fromUtf8( type.readAll() ).trimmed();
        if ( t == QLatin1String( "Battery" ) )
        {
            continue;
        }
        QFile online( supplies.absoluteFilePath( e ) + QStringLiteral( "/online" ) );
        if ( online.open( QIODevice::ReadOnly | QIODevice::Text )
             && QString::fromUtf8( online.readAll() ).trimmed() == QLatin1String( "1" ) )
        {
            return true;
        }
    }
    return false;
}

/*! One row, flattened for Calamares' own model.
 *
 *  The LABEL AND THE DETAIL ARE KEPT APART UNTIL HERE, and then joined with an em dash: "Disk" is
 *  what a reader scans the column for and "12.0 GiB available, 32.0 GiB needed" is the evidence
 *  under it, and a translator handed one pre-joined sentence per state would have to take it apart
 *  again in a language whose word order does not allow it.
 *
 *  BOTH of RequirementEntry's texts get the same function. Upstream keeps an affirmative and a
 *  negated form because its page prints one sentence per FAILURE; this one reports a state per row,
 *  so there is no separate negated form to write and no way for the two to drift.
 */
static Calamares::RequirementEntry
entry( const QString& name,
       const std::function< QString() >& label,
       const std::function< QString() >& detail,
       bool satisfied,
       bool mandatory )
{
    auto text = [ label, detail ]
    {
        const QString d = detail();
        return d.isEmpty() ? label() : QStringLiteral( "%1 \u2014 %2" ).arg( label(), d );
    };
    return { name, text, text, satisfied, mandatory };
}

Calamares::RequirementsList
Requirements::checkRequirements()
{
    Calamares::RequirementsList out;

    const auto want = [ this ]( const char* name ) { return m_toCheck.contains( QLatin1String( name ) ); };
    const auto need = [ this ]( const char* name ) { return m_toRequire.contains( QLatin1String( name ) ); };

    if ( want( "storage" ) )
    {
        const qint64 required = static_cast< qint64 >( m_requiredStorageGiB * GiB );
        const qint64 found = largestInstallableDiskB();
        out.append( entry( QStringLiteral( "storage" ),
                           [] { return tr( "Disk" ); },
                           [ found, required ]
                           {
                               return found > 0 ? tr( "%1 available, %2 needed" )
                                                      .arg( humanBytes( found ), humanBytes( required ) )
                                                : tr( "no disk to install onto, %1 needed" )
                                                      .arg( humanBytes( required ) );
                           },
                           found >= required,
                           need( "storage" ) ) );
    }
    if ( want( "ram" ) )
    {
        const qint64 required = static_cast< qint64 >( m_requiredRamGiB * GiB );
        const qint64 found = static_cast< qint64 >( Calamares::System::instance()->getTotalMemoryB().first );
        // The 0.95 is upstream's and is kept for upstream's reason: what the kernel reports is
        // always a little under the nominal fitting, because the firmware and the video aperture
        // took their share before Linux counted. Without it a machine sold as 4 GB fails a 4 GiB
        // requirement, which is true and useless.
        out.append( entry( QStringLiteral( "ram" ),
                           [] { return tr( "Memory" ); },
                           [ found, required ]
                           { return tr( "%1 available, %2 needed" ).arg( humanBytes( found ), humanBytes( required ) ); },
                           double( found ) >= double( required ) * 0.95,
                           need( "ram" ) ) );
    }
    if ( want( "root" ) )
    {
        const bool isRoot = geteuid() == 0;
        out.append( entry( QStringLiteral( "root" ),
                           [] { return tr( "Administrator access" ); },
                           [ isRoot ] {
                               return isRoot ? QString()
                                             : tr( "the installer is not running with administrator rights" );
                           },
                           isRoot,
                           need( "root" ) ) );
    }
    if ( want( "power" ) )
    {
        const bool hasBattery = batteryExists();
        const bool mains = onMainsPower();
        out.append( entry( QStringLiteral( "power" ),
                           [] { return tr( "Power" ); },
                           [ hasBattery, mains ] {
                               return !hasBattery ? QString()
                                                  : ( mains ? tr( "plugged in" ) : tr( "running on battery" ) );
                           },
                           !hasBattery || mains,
                           need( "power" ) ) );
    }
    if ( want( "internet" ) )
    {
        Calamares::Network::Manager nam;
        const bool online = nam.checkHasInternet();
        // Kept from upstream because other modules read it, not because this page does.
        if ( Calamares::JobQueue::instance() && Calamares::JobQueue::instance()->globalStorage() )
        {
            Calamares::JobQueue::instance()->globalStorage()->insert( QStringLiteral( "hasInternet" ), online );
        }
        out.append( entry( QStringLiteral( "internet" ),
                           [] { return tr( "Network" ); },
                           [ online ] {
                               return online ? tr( "connected" ) : tr( "not connected, not required" );
                           },
                           online,
                           need( "internet" ) ) );
    }
    if ( want( "screen" ) )
    {
        QSize biggest;
        const auto screens = QGuiApplication::screens();
        for ( const auto* screen : screens )
        {
            const QSize s = screen->availableSize();
            if ( !biggest.isValid() || ( biggest.width() * biggest.height() < s.width() * s.height() ) )
            {
                biggest = s;
            }
        }
        const bool big = biggest.isValid() && biggest.width() >= Calamares::windowMinimumWidth
            && biggest.height() >= Calamares::windowMinimumHeight;
        out.append( entry( QStringLiteral( "screen" ),
                           [] { return tr( "Screen" ); },
                           [ biggest ] {
                               // QStringLiteral, not tr(): "1920 x 1080" is punctuation and two
                               // numbers, and a translatable string that no language would
                               // translate is one more <source> that a .ts file can get wrong.
                               return biggest.isValid()
                                   ? QStringLiteral( "%1 \u00d7 %2" ).arg( biggest.width() ).arg( biggest.height() )
                                   : tr( "no screen found" );
                           },
                           big,
                           need( "screen" ) ) );
    }

    return out;
}

#include "moc_Requirements.cpp"
