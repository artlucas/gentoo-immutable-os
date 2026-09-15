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
#include <QMetaType>
#include <QScreen>
#include <QStorageInfo>
#include <QUrl>

#include <functional>
#include <utility>  // std::as_const

#include <unistd.h>  // geteuid

/*! @brief A number from the configuration map, whatever shape YAML left it in.
 *
 * NOT Calamares::getDouble(), AND THIS IS AN UPSTREAM BUG, not a preference. utils/Yaml.cpp
 * turns every unquoted integer scalar into a QVariant holding a *qlonglong*, and
 * utils/Variant.cpp's getDouble() accepts only Int and Double — LongLong is neither, so it
 * falls through and returns the caller's default. The effect is that whether a number in a
 * configuration file is read at all depends on whether somebody wrote ".0" after it:
 *
 *     requiredStorage: 32.0   ->  Double    ->  32.0
 *     requiredStorage: 32     ->  LongLong  ->  the default, silently
 *
 * That is exactly how this installer lost its disk check. The value moved from a hand-written
 * "32.0" to build.conf's MIN_INSTALL_DISK_GB, which is an integer count of GB and renders as
 * "32", and every guard below went on reading zero — so the page announced that a machine with
 * no disk at all could install (plan/24 §11). Nothing in the build could have caught it: the
 * file was correct, the template was correct, and the number was simply never delivered.
 *
 * QVariant::toDouble() accepts every numeric type there is, so this reads both spellings and any
 * future one. Bool is refused rather than converted: YAML reads `on` and `true` as booleans, and
 * a page that quietly treats "requiredStorage: true" as a one-gigabyte minimum is worse than one
 * that falls back to its default and says so.
 */
static double
configNumber( const QVariantMap& map, const QString& key, double dflt )
{
    if ( !map.contains( key ) )
    {
        return dflt;
    }
    const QVariant v = map.value( key );
    if ( v.typeId() == QMetaType::Bool )
    {
        return dflt;
    }
    bool ok = false;
    const double d = v.toDouble( &ok );
    return ok ? d : dflt;
}

static constexpr qint64 GiB = 1024LL * 1024LL * 1024LL;
static constexpr qint64 GB = 1000LL * 1000LL * 1000LL;

/*! @brief A disk size, in the unit printed on the disk: "1.0 TB", never "931.5 GiB".
 *
 * SI, AND IT USED TO BE IEC (plan/24 §3). The old reason was the configuration file —
 * requiredStorage was written in GiB, so reporting "34.4 GB needed" for a config that said 32.0
 * would send whoever set it looking for a bug that is not there. That reason is gone: the key is
 * decimal GB now, rendered from build.conf's MIN_INSTALL_DISK_GB, so the number in the file and
 * the number on the page are the same number.
 *
 * What replaced it is the DISK PAGE. It lists the machine's disks by the size their vendor prints
 * on them, because that is how somebody recognises their own disk in a list of three; a greeting
 * page saying "34.4 GiB needed" two screens earlier would be the only IEC number in the
 * installer, and the one the user is asked to compare against a label on a box.
 */
static QString
diskBytes( qint64 bytes )
{
    return QLocale().formattedDataSize( bytes, 1, QLocale::DataSizeSIFormat );
}

/*! @brief A memory size, which is NOT the same question and keeps IEC.
 *
 * RAM really is sold in binary multiples — a 4 GB module is 4 GiB — so SI here would report a
 * machine with exactly 4 GiB as having "4.3 GB" and read as a rounding error. Disks are decimal
 * and memory is binary because that is what the two industries do, and an installer that picked
 * one unit for both would be wrong about one of them.
 */
static QString
memoryBytes( qint64 bytes )
{
    return QLocale().formattedDataSize( bytes, 1, QLocale::DataSizeIecFormat );
}

Requirements::Requirements( QObject* parent )
    : QObject( parent )
{
}

void
Requirements::setConfigurationMap( const QVariantMap& configurationMap )
{
    // EVERY KEY THIS PAGE READS LIVES UNDER `requirements:`, one level down, and until now this
    // function read them at the top level — where there is nothing at all. greeting.conf keeps the
    // shape of the stock welcome module's file it replaced, because that is the shape its readers
    // expect and GeneralRequirements takes the same submap; both the rendered file and the module's
    // packaged fallback have always had the block, and the comments inside it describe it. What was
    // missing was the descent into it. `check` and `required` came back empty, both thresholds came
    // back zero, checkRequirements() returned nothing — and RequirementsModel::satisfiedMandatory()
    // is std::none_of over that empty list, which is true. The page then announced that a machine
    // with no disk in it could install this system, having run not one of its six checks (plan/23 §8).
    bool haveBlock = false;
    const QVariantMap requirements
        = Calamares::getSubMap( configurationMap, QStringLiteral( "requirements" ), haveBlock );

    m_toCheck = Calamares::getStringList( requirements, QStringLiteral( "check" ) );
    m_toRequire = Calamares::getStringList( requirements, QStringLiteral( "required" ) );
    // DECIMAL GB since plan/24 §3, and the key keeps upstream's name because nothing of
    // upstream's reads it — GeneralRequirements is not in this medium's sequence at all. The
    // value is rendered from build.conf's MIN_INSTALL_DISK_GB, which the disk page's
    // minimumDiskSize is rendered from as well, so the page that blocks Next and the page that
    // lists the disks cannot disagree about how big a disk has to be.
    m_requiredStorageGB = configNumber( requirements, QStringLiteral( "requiredStorage" ), 0.0 );
    m_requiredRamGiB = configNumber( requirements, QStringLiteral( "requiredRam" ), 0.0 );

    // A PAGE THAT CHECKS NOTHING MUST NOT SAY YES, and this is the second half of the same bug.
    // What this function used to do with a threshold it could not read was delete the check —
    // m_toCheck.removeAll( "storage" ) — which is verbatim the upstream escape hatch quoted in
    // Requirements.h as the reason this file exists. Inheriting it re-opened the hole in silence:
    // a page with no configuration removed all of its checks, passed, and said so cheerfully. A
    // requirement this medium cannot evaluate is a broken medium, not a satisfied requirement, so
    // nothing is removed below. The rows stay, and they fail.
    m_configBroken = false;
    if ( !haveBlock )
    {
        cError() << "greeting: this module's configuration has no 'requirements:' block, so there "
                    "is nothing to check and no verdict to give. Keys written at the top level of "
                    "greeting.conf are not read at all.";
        m_configBroken = true;
    }
    else if ( m_toCheck.isEmpty() )
    {
        cError() << "greeting: 'requirements:' asks for no checks at all, so this page has nothing "
                    "to report a verdict on.";
        m_configBroken = true;
    }
    if ( m_toCheck.contains( QStringLiteral( "storage" ) ) && m_requiredStorageGB <= 0.0 )
    {
        cError() << "greeting: requiredStorage is missing or zero — the disk row will FAIL rather "
                    "than be skipped, which is what plan/22 §3a exists to stop happening.";
    }
    if ( m_toCheck.contains( QStringLiteral( "ram" ) ) && m_requiredRamGiB <= 0.0 )
    {
        cError() << "greeting: requiredRam is missing or zero — the memory row will FAIL.";
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
    const QStringList urlStrings = Calamares::getStringList( requirements, QStringLiteral( "internetCheckUrl" ) );
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
 *  what a reader scans the column for and "12.9 GB available, 32.0 GB needed" is the evidence
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

    // FIRST, because a medium that cannot check is worse news than any single failed check, and
    // because with no configuration at all there are no other rows for the reader to look at.
    if ( m_configBroken )
    {
        out.append( entry( QStringLiteral( "configuration" ),
                           [] { return tr( "Installer configuration" ); },
                           []
                           {
                               return tr( "this installer cannot tell whether this computer meets "
                                          "its requirements — see the installer log" );
                           },
                           false,
                           true ) );
    }

    const auto want = [ this ]( const char* name ) { return m_toCheck.contains( QLatin1String( name ) ); };
    const auto need = [ this ]( const char* name ) { return m_toRequire.contains( QLatin1String( name ) ); };

    if ( want( "storage" ) )
    {
        const qint64 required = static_cast< qint64 >( m_requiredStorageGB * GB );
        const qint64 found = largestInstallableDiskB();
        // Without a threshold there is no sentence to write: "0 bytes needed" is how the disk page
        // reported the same missing number, and it reads as a satisfied requirement rather than an
        // unreadable one. `found >= required` would be true for the same reason, which is why the
        // threshold is part of the verdict and not just of the text.
        const bool haveThreshold = m_requiredStorageGB > 0.0;
        out.append( entry( QStringLiteral( "storage" ),
                           [] { return tr( "Disk" ); },
                           [ found, required, haveThreshold ]
                           {
                               if ( !haveThreshold )
                               {
                                   return tr( "this installer was not told how large a disk it needs" );
                               }
                               return found > 0 ? tr( "%1 available, %2 needed" )
                                                      .arg( diskBytes( found ), diskBytes( required ) )
                                                : tr( "no disk to install onto, %1 needed" )
                                                      .arg( diskBytes( required ) );
                           },
                           haveThreshold && found >= required,
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
        const bool haveThreshold = m_requiredRamGiB > 0.0;
        out.append( entry( QStringLiteral( "ram" ),
                           [] { return tr( "Memory" ); },
                           [ found, required, haveThreshold ]
                           {
                               if ( !haveThreshold )
                               {
                                   return tr( "this installer was not told how much memory it needs" );
                               }
                               return tr( "%1 available, %2 needed" ).arg( memoryBytes( found ), memoryBytes( required ) );
                           },
                           haveThreshold && double( found ) >= double( required ) * 0.95,
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
