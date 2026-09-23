/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "DiskConfig.h"

#include "DiskModel.h"

#include "Branding.h"
#include "GlobalStorage.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"
#include "utils/Variant.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaType>
#include <QProcess>
#include <QStorageInfo>
#include <QStringList>

// DiskModel::formatSize() and DiskModel::productName() are used unqualified nowhere in this
// file: sizes and the product name are the model's statics precisely so that the rows and the
// plan bar under them cannot disagree about how to write a number, and spelling out where they
// come from is the cheapest way to keep a second local formatter from ever appearing here.
// See plan/24 §3 for why they are decimal.

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

/*! @brief The first line of a sysfs attribute, trimmed; empty when it is not there. */
static QString
sysfsRead( const QString& path )
{
    QFile f( path );
    if ( !f.open( QIODevice::ReadOnly | QIODevice::Text ) )
    {
        return {};
    }
    return QString::fromUtf8( f.readAll() ).trimmed();
}

/*! @brief The /sys/block name of the disk this installer booted from, or empty.
 *
 * THE ONE FUNCTION HERE THAT PROTECTS DATA. QStorageInfo gives the device node mounted at "/" —
 * "/dev/sda2", "/dev/nvme0n1p3" — and a partition of disk D is always a directory INSIDE
 * /sys/block/D, so the containment test needs no string surgery on partition-number suffixes.
 * That matters: "nvme0n1p3" chopped by a trailing-digits rule gives "nvme0n1p", which matches
 * nothing, and the medium would appear in the picker.
 *
 * It is the same test the greeting page's Requirements::largestInstallableDiskB() makes, written
 * twice because the two live in different plugins and neither installs a header the other could
 * include. tests/test-installer.sh asserts both are still there.
 */
static QString
liveMediumDisk()
{
    const QString rootNode = QFileInfo( QString::fromUtf8( QStorageInfo::root().device() ) ).fileName();
    if ( rootNode.isEmpty() )
    {
        // Nothing is mounted at / that looks like a device. Rather than guess, say so loudly: the
        // consequence of getting this wrong is offering to erase the disk we are running from.
        cWarning() << "disk: the root filesystem has no device node, so the installation medium "
                      "cannot be identified and every disk will be offered. This should not "
                      "happen on this medium, where the live root IS a partition.";
        return {};
    }
    const QDir sysBlock( QStringLiteral( "/sys/block" ) );
    const auto disks = sysBlock.entryList( QDir::Dirs | QDir::NoDotAndDotDot | QDir::System );
    for ( const QString& disk : disks )
    {
        if ( rootNode == disk
             || QFileInfo::exists( QStringLiteral( "/sys/block/%1/%2" ).arg( disk, rootNode ) ) )
        {
            return disk;
        }
    }
    return {};
}

/*! @brief `lsblk --json`, keyed by kernel name. Best effort, and never load-bearing.
 *
 * Enrichment only: what is on each disk, for the second line of its row. Everything the page
 * DECIDES — which disks exist, how big they are, which one is the medium — comes from sysfs
 * above, so a medium whose lsblk moved, changed its JSON or is simply missing still draws a
 * usable picker with a vaguer row. Blocking the page on a helper binary would be the worse
 * trade by a wide margin.
 */
static QHash< QString, QJsonObject >
lsblkByName()
{
    QHash< QString, QJsonObject > out;
    QProcess p;
    p.start( QStringLiteral( "lsblk" ),
             { QStringLiteral( "--json" ), QStringLiteral( "--bytes" ), QStringLiteral( "--paths" ),
               QStringLiteral( "--output" ),
               QStringLiteral( "NAME,KNAME,TYPE,SIZE,FSTYPE,LABEL,PARTLABEL" ) } );
    if ( !p.waitForFinished( 5000 ) || p.exitStatus() != QProcess::NormalExit || p.exitCode() != 0 )
    {
        cWarning() << "disk: lsblk did not answer; rows will not say what is on each disk."
                   << p.errorString();
        return out;
    }
    QJsonParseError err {};
    const QJsonDocument doc = QJsonDocument::fromJson( p.readAllStandardOutput(), &err );
    if ( err.error != QJsonParseError::NoError || !doc.isObject() )
    {
        cWarning() << "disk: lsblk's output is not the JSON object this expects:" << err.errorString();
        return out;
    }
    const QJsonArray devices = doc.object().value( QStringLiteral( "blockdevices" ) ).toArray();
    for ( const QJsonValue& v : devices )
    {
        const QJsonObject o = v.toObject();
        // --paths makes `name` a /dev node; `kname` is the kernel name, which is the /sys/block
        // directory and therefore the key this is joined on.
        const QString kname = o.value( QStringLiteral( "kname" ) ).toString();
        if ( !kname.isEmpty() )
        {
            out.insert( QFileInfo( kname ).fileName(), o );
        }
    }
    return out;
}

/*! @brief The device node of partition NUMBER on DISK — /dev/sda + 4 -> /dev/sda4,
 *  /dev/nvme0n1 + 4 -> /dev/nvme0n1p4.
 *
 * The reverse of the rule scripts/lib/layout.sh's `inspect` strips off a node to find the
 * partition number (plan/33 §4): a "p" goes in front of the number only when the disk's own
 * node already ends in a digit, which is true for nvme/mmcblk and false for sdX/vdX/hdX.
 */
static QString
partitionNode( const QString& disk, int number )
{
    const bool diskEndsInDigit = !disk.isEmpty() && disk.at( disk.length() - 1 ).isDigit();
    return disk + ( diskEndsInDigit ? QStringLiteral( "p" ) : QString() ) + QString::number( number );
}

/*! @brief lsblk's FSTYPE for one partition, or empty. Best effort, like lsblkByName() above. */
static QString
partitionFstype( const QString& partition )
{
    QProcess p;
    p.start( QStringLiteral( "lsblk" ),
             { QStringLiteral( "--noheadings" ), QStringLiteral( "--output" ), QStringLiteral( "FSTYPE" ),
               partition } );
    if ( !p.waitForFinished( 5000 ) || p.exitStatus() != QProcess::NormalExit || p.exitCode() != 0 )
    {
        return {};
    }
    return QString::fromUtf8( p.readAllStandardOutput() ).trimmed();
}

// ================================ DiskConfig =================================================

DiskConfig::DiskConfig( QObject* parent )
    : QObject( parent )
    , m_model( new DiskModel( this ) )
{
    CALAMARES_RETRANSLATE_SLOT( &DiskConfig::retranslate );
}

void
DiskConfig::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_minimumDiskGB = configNumber( configurationMap, QStringLiteral( "minimumDiskSize" ), 0.0 );
    const double espMiB = configNumber( configurationMap, QStringLiteral( "espSizeMiB" ), 0.0 );
    const double slotMiB = configNumber( configurationMap, QStringLiteral( "rootSlotSizeMiB" ), 0.0 );
    m_espBytes = static_cast< qint64 >( espMiB ) * 1024LL * 1024LL;
    m_slotBytes = static_cast< qint64 >( slotMiB ) * 1024LL * 1024LL;
    // A STRING, so Calamares::getString() rather than configNumber() — see the note on
    // configNumber() above the disk plugin's file-static definition, and DiskConfig.h's comment
    // on the five-call-site pin (plan/33 §5).
    m_layoutHelper = Calamares::getString( configurationMap, QStringLiteral( "layoutHelper" ) );

    // Loud, and then FATAL TO THE PAGE rather than defaulted, for the reason the greeting page's
    // requiredStorage guard gives: a minimum that defaults to zero is the same thing as no
    // minimum, and here it would offer to install onto a disk the job then refuses — an installer
    // that says yes on one screen and fails on the next.
    if ( m_minimumDiskGB <= 0.0 )
    {
        cError() << "disk: minimumDiskSize is missing or zero. It is rendered from build.conf's "
                    "MIN_INSTALL_DISK_GB by stage 40; a medium that reached this point has a "
                    "rendering bug. Every disk will be offered, including ones too small to hold "
                    "the layout.";
    }
    if ( m_espBytes <= 0 || m_slotBytes <= 0 )
    {
        cError() << "disk: espSizeMiB/rootSlotSizeMiB are missing, so the page cannot say what it "
                    "is about to do to the disk. The bar will be empty.";
    }
    if ( m_layoutHelper.isEmpty() )
    {
        // Not fatal, unlike the two guards above: a page that cannot tell whether a disk can be
        // kept still does everything plan/24 already asked of it, offered by nobody rather than
        // shown wrong. Every disk simply keeps Keep::None.
        cWarning() << "disk: layoutHelper is missing from the configuration, so no disk can be "
                      "offered a keep — every disk is treated as a fresh install.";
    }

    rescan();
}

QAbstractItemModel*
DiskConfig::disksModel() const
{
    return m_model;
}

QVector< DiskModel::Entry >
DiskConfig::enumerate() const
{
    const QString medium = liveMediumDisk();
    const QHash< QString, QJsonObject > extra = lsblkByName();
    const qint64 minimumBytes = static_cast< qint64 >( m_minimumDiskGB * 1000.0 * 1000.0 * 1000.0 );

    QVector< DiskModel::Entry > installable, blocked;
    const QDir sysBlock( QStringLiteral( "/sys/block" ) );
    const auto names = sysBlock.entryList( QDir::Dirs | QDir::NoDotAndDotDot | QDir::System );
    for ( const QString& name : names )
    {
        // Not disks: loopback, ramdisks, zram, optical, device-mapper and MD arrays. The same
        // list the greeting page's checker skips, and for the same reason — an installer that
        // offered to write the root image into /dev/zram0 would be a very short bug report.
        if ( name.startsWith( QLatin1String( "loop" ) ) || name.startsWith( QLatin1String( "ram" ) )
             || name.startsWith( QLatin1String( "zram" ) ) || name.startsWith( QLatin1String( "sr" ) )
             || name.startsWith( QLatin1String( "dm-" ) ) || name.startsWith( QLatin1String( "md" ) ) )
        {
            continue;
        }

        const QString base = QStringLiteral( "/sys/block/%1" ).arg( name );
        bool ok = false;
        // ALWAYS 512-byte units, whatever the drive's own sector size: /sys/block/*/size is
        // documented in 512-byte sectors and does not follow queue/logical_block_size. A 4Kn disk
        // read through the logical size would appear eight times its real capacity — and would
        // then pass a minimum-size check it should have failed.
        const qint64 sectors = sysfsRead( base + QStringLiteral( "/size" ) ).toLongLong( &ok );
        if ( !ok || sectors <= 0 )
        {
            continue;
        }

        DiskModel::Entry e;
        e.kernelName = name;
        e.node = QStringLiteral( "/dev/%1" ).arg( name );
        e.bytes = sectors * 512LL;
        e.removable = sysfsRead( base + QStringLiteral( "/removable" ) ) == QLatin1String( "1" );

        // The name on the box, as far as the kernel knows it. NVMe puts the whole thing in
        // `model`; SCSI and USB bridges split it across `vendor` and `model` and pad both.
        // THE VENDOR SURVIVES ONLY WHEN IT IS A MAKER'S NAME, and what each bus puts in that
        // attribute is why: virtio offers a PCI vendor ID ("0x1af4") and no model at all — which
        // is how a row of this page once read "0x1af4" where a name belongs — and SATA reports
        // "ATA", the bus rather than the maker, on disks whose model already begins with the
        // maker ("WDC WD10EZEX…"). USB is the case the attribute is FOR: "SanDisk" + "Ultra".
        const QString vendor = sysfsRead( base + QStringLiteral( "/device/vendor" ) );
        const QString model = sysfsRead( base + QStringLiteral( "/device/model" ) );
        const bool vendorIsAName = !vendor.isEmpty() && !vendor.startsWith( QLatin1String( "0x" ) )
            && vendor != QLatin1String( "ATA" ) && !model.startsWith( vendor );
        e.title = ( vendorIsAName ? vendor + QLatin1Char( ' ' ) + model : model ).simplified();

        // The bus, as the bus names itself. Read as a LINK, not a file: sysfs subsystems are
        // symlinks, and opening one gets a directory. Stored raw — the word for a bus is said by
        // DiskModel when the row is read (Entry::transport), because a word built here would keep
        // the first language's spelling for the rest of the session.
        e.transport = QFileInfo( base + QStringLiteral( "/device/subsystem" ) ).symLinkTarget()
                          .section( QLatin1Char( '/' ), -1 );

        if ( name == medium )
        {
            e.block = DiskModel::Block::LiveMedium;
        }
        else if ( sysfsRead( base + QStringLiteral( "/ro" ) ) == QLatin1String( "1" ) )
        {
            e.block = DiskModel::Block::ReadOnly;
        }
        else if ( minimumBytes > 0 && e.bytes < minimumBytes )
        {
            e.block = DiskModel::Block::TooSmall;
        }

        // ---- the second line, from lsblk ------------------------------------------------
        const QJsonObject o = extra.value( name );
        const QJsonArray children = o.value( QStringLiteral( "children" ) ).toArray();
        QStringList parts;
        for ( const QJsonValue& cv : children )
        {
            const QJsonObject c = cv.toObject();
            if ( c.value( QStringLiteral( "type" ) ).toString() != QLatin1String( "part" ) )
            {
                continue;
            }
            ++e.partitions;
            if ( parts.count() >= 3 )
            {
                continue;
            }
            QString label = c.value( QStringLiteral( "partlabel" ) ).toString();
            if ( label.isEmpty() )
            {
                label = c.value( QStringLiteral( "label" ) ).toString();
            }
            const QString fs = c.value( QStringLiteral( "fstype" ) ).toString();
            if ( label.isEmpty() )
            {
                label = fs.isEmpty() ? tr( "unformatted" ) : fs;
            }
            // The size, but only on the partitions big enough to be what the user thinks of as
            // "their" data. A row reading "EFI (vfat, 1.1 GB), Windows (NTFS, 420 GB)" spends its
            // width on the partition nobody is looking for.
            const qint64 pb = static_cast< qint64 >( c.value( QStringLiteral( "size" ) ).toDouble() );
            if ( pb > 0 && e.bytes > 0 && pb * 10 >= e.bytes )
            {
                label = fs.isEmpty() ? tr( "%1 (%2)" ).arg( label, DiskModel::formatSize( pb ) )
                                     : tr( "%1 (%2, %3)" ).arg( label, fs, DiskModel::formatSize( pb ) );
            }
            if ( e.firstPartition.isEmpty() )
            {
                e.firstPartition = label;
            }
            parts.append( label );
        }
        if ( e.partitions > parts.count() )
        {
            parts.append( QStringLiteral( "…" ) );
        }
        if ( !extra.contains( name ) )
        {
            e.contents.clear();  // lsblk could not be asked; data() says so
        }
        else if ( e.partitions == 0 )
        {
            e.contents = o.value( QStringLiteral( "fstype" ) ).toString().isEmpty()
                ? tr( "Empty — no partition table" )
                : tr( "One filesystem, no partition table" );
        }
        else
        {
            e.contents = tr( "%n partition(s) — %1", "disk contents", e.partitions )
                             .arg( parts.join( QStringLiteral( ", " ) ) );
        }

        // ---- can this disk be KEPT? (plan/33 §4/§5) --------------------------------------
        // The cheap gate first, over EVERY child rather than the first three `parts` stopped
        // building label text for above: a partition literally labelled "var" existing at all.
        // Only a disk that passes it is worth a `sfdisk --dump` and a subprocess — which is
        // every disk that is obviously not this distro's install, i.e. nearly all of them.
        bool hasVarPartition = false;
        for ( const QJsonValue& cv : children )
        {
            if ( cv.toObject().value( QStringLiteral( "partlabel" ) ).toString() == QLatin1String( "var" ) )
            {
                hasVarPartition = true;
                break;
            }
        }
        if ( e.block == DiskModel::Block::None && hasVarPartition )
        {
            inspectDisk( e );
        }

        // INSTALLABLE DISKS FIRST, and the blocked ones after them in one block. That ordering is
        // what makes the keyboard usable: setCurrentIndex() refuses a blocked row, so a list that
        // interleaved them would leave Down doing nothing at unpredictable places rather than
        // simply stopping at the end of the disks that can be chosen.
        if ( e.block == DiskModel::Block::None )
        {
            installable.append( e );
        }
        else
        {
            blocked.append( e );
        }
    }
    return installable + blocked;
}

void
DiskConfig::inspectDisk( DiskModel::Entry& e ) const
{
    if ( m_layoutHelper.isEmpty() || m_espBytes <= 0 || m_slotBytes <= 0 )
    {
        return;  // e.keep stays None — nothing to compare a disk against
    }

    QProcess dump;
    dump.start( QStringLiteral( "sfdisk" ), { QStringLiteral( "--dump" ), e.node } );
    if ( !dump.waitForFinished( 5000 ) || dump.exitStatus() != QProcess::NormalExit || dump.exitCode() != 0 )
    {
        // The gate that got us here already saw a partition literally labelled "var" through
        // lsblk, so this is not the ordinary "blank disk" case — it is sfdisk itself failing on
        // a disk that looked like an install. Conservative rather than silent: refuse rather than
        // falling back to None, which would tell the user the disk is empty when it may not be.
        cWarning() << "disk: sfdisk --dump failed on" << e.node << "- it will not offer to keep data";
        e.keep = DiskModel::Keep::Refused;
        return;
    }
    const QByteArray dumpOut = dump.readAllStandardOutput();

    QProcess helper;
    helper.start( m_layoutHelper,
                  { QStringLiteral( "inspect" ), QStringLiteral( "--device" ), e.node,
                    QStringLiteral( "--esp-mib" ), QString::number( m_espBytes / ( 1024LL * 1024LL ) ),
                    QStringLiteral( "--slot-mib" ), QString::number( m_slotBytes / ( 1024LL * 1024LL ) ) } );
    if ( !helper.waitForStarted( 5000 ) )
    {
        cWarning() << "disk: could not start" << m_layoutHelper << "to inspect" << e.node;
        e.keep = DiskModel::Keep::Refused;
        return;
    }
    helper.write( dumpOut );
    helper.closeWriteChannel();
    if ( !helper.waitForFinished( 5000 ) || helper.exitStatus() != QProcess::NormalExit
         || helper.exitCode() != 0 )
    {
        cWarning() << "disk:" << m_layoutHelper << "failed inspecting" << e.node << "-"
                   << helper.readAllStandardError();
        e.keep = DiskModel::Keep::Refused;
        return;
    }

    // key=value, one per line (plan/33 §4) — never a GPT GUID among them, which is the point of
    // asking the helper rather than reading the dump here.
    QHash< QString, QString > kv;
    const auto lines = helper.readAllStandardOutput().split( '\n' );
    for ( const QByteArray& raw : lines )
    {
        const QString line = QString::fromUtf8( raw ).trimmed();
        const int eq = line.indexOf( QLatin1Char( '=' ) );
        if ( eq <= 0 )
        {
            continue;
        }
        kv.insert( line.left( eq ), line.mid( eq + 1 ) );
    }

    const QString verdict = kv.value( QStringLiteral( "verdict" ) );
    if ( verdict == QLatin1String( "none" ) )
    {
        return;  // e.keep stays None; the gate above was a false alarm (wrong type, say)
    }
    e.installedVersion = kv.value( QStringLiteral( "installed" ) );
    if ( verdict != QLatin1String( "keep" ) )
    {
        // "refuse" — the reason is for the log, not for this page: §3 gives the user one
        // sentence regardless of which of `inspect`'s four reasons applies.
        e.keep = DiskModel::Keep::Refused;
        return;
    }

    // The partition TABLE says keep; the FILESYSTEM still has to be ext4, or disksetup's own
    // e2fsck -p (§6) would be the first thing that ever checked it — after the point nothing has
    // been written yet stops being true. lsblk, not the helper: `inspect` is a pure text function
    // over a partition table and never mounts or reads a filesystem (plan/33 §4).
    const QString varNode = partitionNode( e.node, kv.value( QStringLiteral( "var" ) ).toInt() );
    if ( partitionFstype( varNode ) != QLatin1String( "ext4" ) )
    {
        e.keep = DiskModel::Keep::Refused;
        return;
    }

    bool sizesOk = true;
    const auto mib = [ &kv, &sizesOk ]( const QString& key ) -> qint64
    {
        bool ok = false;
        const qint64 v = kv.value( key ).toLongLong( &ok );
        sizesOk = sizesOk && ok;
        return v * 1024LL * 1024LL;
    };
    e.keptEspBytes = mib( QStringLiteral( "esp_mib" ) );
    e.keptSlotBytes = mib( QStringLiteral( "slot_mib" ) );
    e.keptSpareBytes = mib( QStringLiteral( "spare_mib" ) );
    e.keptVarBytes = mib( QStringLiteral( "var_mib" ) );
    if ( !sizesOk )
    {
        cWarning() << "disk:" << m_layoutHelper << "printed a keep verdict for" << e.node
                   << "with unreadable sizes";
        e.keep = DiskModel::Keep::Refused;
        return;
    }

    e.keep = DiskModel::Keep::Offered;
}

void
DiskConfig::rescan()
{
    const QString wasNode = selectedNode();

    m_model->setEntries( enumerate() );
    // The model reset dropped every row, so nothing is selected and nothing is agreed to. Both
    // have to be said out loud rather than assumed: a stale m_currentIndex would point into a
    // list that has been rebuilt, and a stale m_confirmed would be an answer about a disk that
    // may no longer be there.
    m_currentIndex = -1;
    m_confirmed = false;

    int restore = -1;
    if ( !wasNode.isEmpty() )
    {
        // Keep the user's disk across a rescan when it is still there and still usable. The
        // confirmation is NOT restored with it — "Check again" changed what the page knows, so
        // the question is asked again.
        for ( int i = 0; i < m_model->rowCount(); ++i )
        {
            if ( m_model->entries().at( i ).node == wasNode && m_model->isInstallable( i ) )
            {
                restore = i;
                break;
            }
        }
    }
    if ( restore < 0 && m_model->installableCount() == 1 )
    {
        // One disk, so there is nothing to choose. Selecting it is a convenience; answering the
        // confirmation for the user would be removing the only deliberate act on the page — and
        // the dialog asks for it on every press of Next anyway (plan/26 §1).
        restore = 0;  // installable rows sort first
    }

    emit disksChanged();
    emit currentIndexChanged();
    emit confirmedChanged();
    emit planChanged();
    emit nextEnabledChanged();
    emit retranslated();  // the headline depends on how many disks there are

    if ( restore >= 0 )
    {
        setCurrentIndex( restore );
    }
    cDebug() << "disk:" << m_model->rowCount() << "disks," << m_model->installableCount()
             << "installable";
}

void
DiskConfig::setCurrentIndex( int index )
{
    // REFUSED, not clamped, for anything that is not a disk this installer may write to. The QML
    // puts back whatever comes out of currentIndexChanged, so a refusal here is what stops the
    // highlight sitting on a row the install would never use.
    if ( index != -1 && !m_model->isInstallable( index ) )
    {
        return;
    }
    if ( index == m_currentIndex )
    {
        return;
    }
    m_currentIndex = index;
    // TICKED BY DEFAULT the instant the new selection offers it (plan/33 §1) — the choice that
    // cannot lose anything is the one a user has to act to leave. Recomputed on every change,
    // including rescan()'s restore of a disk that was already selected, so a fresh scan's new
    // information about the SAME disk is never left carrying a stale tick.
    m_keepData = ( index != -1 && m_model->entries().at( index ).keep == DiskModel::Keep::Offered );
    // The answer was about a disk, not about the page. Changing the disk withdraws it — mostly a
    // formality now that onLeave() withdraws it too, but a dialog left pending over a changed
    // selection is exactly the thing neither rule should have to be the only one preventing.
    setConfirmed( false );
    emit currentIndexChanged();
    emit keepDataChanged();
    emit planChanged();
    emit nextEnabledChanged();
    // And retranslated(), though nothing translated: confirmSubtitle is a string property that
    // follows the selection as well as the language, and this is its change signal — the same
    // loosening rescan() makes for the headline.
    emit retranslated();
}

void
DiskConfig::setKeepData( bool keep )
{
    // Ignored unless the SELECTED row actually offers it — a stray write while nothing is
    // selected, or while the row cannot be kept, must not put the page in a state its own
    // properties say is impossible.
    if ( !keepAvailable() || keep == m_keepData )
    {
        return;
    }
    m_keepData = keep;
    // Every confirmation string follows this (plan/33 §9): what is kept, what is erased, the
    // dialog's title and accept label. Re-asking rather than trusting a stale answer is the same
    // loosening setCurrentIndex() already makes for confirmSubtitle on a changed selection.
    setConfirmed( false );
    emit keepDataChanged();
    emit planChanged();
    emit retranslated();
}

void
DiskConfig::setConfirmed( bool confirmed )
{
    if ( confirmed == m_confirmed )
    {
        return;
    }
    m_confirmed = confirmed;
    emit confirmedChanged();
    // nextEnabled() no longer reads m_confirmed (the button lights for a disk alone), but the
    // re-ask is harmless and keeps this setter honest about everything that could depend on the
    // answer — isAtEnd() among them, which the view step re-reads through its own connections.
    emit nextEnabledChanged();
}

void
DiskConfig::requestConfirmation()
{
    // The dialog is QML's to draw; this is only the knock. Re-asking with one already open is a
    // no-op on the QML side (open() on an open dialog), which is the right failure for a user
    // who finds the window's Next twice.
    emit confirmationRequested();
}

void
DiskConfig::acceptConfirmation()
{
    setConfirmed( true );
}

bool
DiskConfig::nextEnabled() const
{
    // THE DISK, AND NOTHING ELSE. This answers "may the button be pressed", not "may the page be
    // left": pressing it while unconfirmed opens the confirmation dialog instead (DiskViewStep's
    // isAtEnd()/next() pair), and the erase is agreed to there, on every press (plan/26 §1).
    return m_model->isInstallable( m_currentIndex );
}

int
DiskConfig::diskCount() const
{
    return m_model->rowCount();
}

int
DiskConfig::installableCount() const
{
    return m_model->installableCount();
}

bool
DiskConfig::keepOffered() const
{
    return m_model->isInstallable( m_currentIndex )
        && m_model->entries().at( m_currentIndex ).keep != DiskModel::Keep::None;
}

bool
DiskConfig::keepAvailable() const
{
    return m_model->isInstallable( m_currentIndex )
        && m_model->entries().at( m_currentIndex ).keep == DiskModel::Keep::Offered;
}

bool
DiskConfig::anyRowOffersKeep() const
{
    for ( const DiskModel::Entry& e : m_model->entries() )
    {
        if ( e.block == DiskModel::Block::None && e.keep == DiskModel::Keep::Offered )
        {
            return true;
        }
    }
    return false;
}

bool
DiskConfig::keeping() const
{
    return keepAvailable() && m_keepData;
}

QString
DiskConfig::minimumSizeText() const
{
    return DiskModel::formatSize( static_cast< qint64 >( m_minimumDiskGB * 1000.0 * 1000.0 * 1000.0 ) );
}

QString
DiskConfig::headline() const
{
    switch ( installableCount() )
    {
    case 0:
        return tr( "No disk can be used for the installation." );
    case 1:
        return tr( "This computer has one disk." );
    default:
        return tr( "Where should %1 be installed?" ).arg( DiskModel::productName() );
    }
}

QString
DiskConfig::subheadline() const
{
    // WHICH ROW SHOWS DEPENDS ON THE DISK, NOT ON THE TICK, and the subheadline follows the same
    // rule for the same reason (plan/33 §3): it says what the MACHINE can do, so it depends on
    // whether ANY installable row offers a keep — anyRowOffersKeep() — never on m_currentIndex
    // or m_keepData, which is what nothing on this page is allowed to move under the cursor.
    switch ( installableCount() )
    {
    case 0:
        return tr( "%1 needs a disk of at least %2 that it is not itself running from." )
            .arg( DiskModel::productName(), minimumSizeText() );
    case 1:
        if ( anyRowOffersKeep() )
        {
            return tr( "%1 is already on it. You can reinstall it and keep your files, apps and "
                       "settings." )
                .arg( DiskModel::productName() );
        }
        return tr( "%1 will be installed on it, and everything on it now will be erased." )
            .arg( DiskModel::productName() );
    default:
        if ( anyRowOffersKeep() )
        {
            return tr( "A disk that already has %1 on it can keep your files, apps and settings. "
                       "Everything else on the disk you choose is erased." )
                .arg( DiskModel::productName() );
        }
        return tr( "Everything on the disk you choose will be erased. Nothing else on this "
                   "computer is changed." );
    }
}

QVariantList
DiskConfig::plan() const
{
    QVariantList out;
    if ( !m_model->isInstallable( m_currentIndex ) || m_espBytes <= 0 || m_slotBytes <= 0 )
    {
        return out;
    }
    const DiskModel::Entry& e = m_model->entries().at( m_currentIndex );

    const auto seg = [ &out ]( const QString& label, qint64 bytes )
    {
        QVariantMap m;
        m.insert( QStringLiteral( "label" ), label );
        m.insert( QStringLiteral( "sizeText" ), DiskModel::formatSize( bytes ) );
        // double, because QML has no 64-bit integer and a TB-sized disk does not fit in an int.
        // Only ever used to give the bar its proportions, where a double is exact enough.
        m.insert( QStringLiteral( "bytes" ), double( bytes ) );
        out.append( m );
    };

    if ( keeping() )
    {
        // The disk's OWN sizes — inspectDisk()'s kept* fields, straight from `inspect`'s
        // esp_mib/slot_mib/spare_mib/var_mib — not this build's ESP_SIZE_MIB/ROOT_SLOT_SIZE_MIB.
        // A disk kept across several builds may have been partitioned by an earlier one with
        // different geometry, and the bar is meant to show what is really there (plan/33 §5).
        seg( tr( "Boot" ), e.keptEspBytes );
        seg( tr( "System" ), e.keptSlotBytes );
        seg( tr( "Reserved for updates" ), e.keptSpareBytes );
        seg( tr( "Your files (kept)" ), e.keptVarBytes );
        return out;
    }

    // The two alignment megabytes lib/layout.sh accounts for: one leading, one for the backup GPT
    // at the end. Subtracted here as well so the bar adds up to the disk rather than to slightly
    // more than it.
    const qint64 rest = e.bytes - ( 2LL * 1024LL * 1024LL ) - m_espBytes - 2LL * m_slotBytes;
    // On-disk order, which is also the order they are explained in: the part that boots, the
    // system, the half kept back for the next version, and then everything the user owns.
    seg( tr( "Boot" ), m_espBytes );
    seg( tr( "System" ), m_slotBytes );
    seg( tr( "Reserved for updates" ), m_slotBytes );
    seg( tr( "Your files" ), rest > 0 ? rest : 0 );
    return out;
}

QString
DiskConfig::lossSummary() const
{
    if ( !m_model->isInstallable( m_currentIndex ) )
    {
        return {};
    }
    const DiskModel::Entry& e = m_model->entries().at( m_currentIndex );

    QString s;
    if ( e.keep != DiskModel::Keep::None )
    {
        // A disk that already holds a recognisable install is NAMED, not counted (plan/33 §3,
        // §9) — this sentence never says "partitions" for a disk it is describing software on,
        // whichever way the tick goes.
        const QString named = DiskModel::productName() + QLatin1Char( ' ' ) + e.installedVersion;
        if ( keeping() )
        {
            const auto* branding = Calamares::Branding::instance();
            const QString versioned = branding
                ? branding->string( Calamares::Branding::VersionedName )
                : named;
            s = tr( "The system on this disk is replaced with %1. Its accounts, files, apps and "
                    "settings are kept." )
                    .arg( versioned );
        }
        else
        {
            s = tr( "%1 and everything saved on it will be deleted, including its accounts, "
                    "files, apps and settings." )
                    .arg( named );
            if ( e.keep == DiskModel::Keep::Refused )
            {
                // §3's "the warning gains the reason in one sentence" — ONE sentence regardless
                // of which of `inspect`'s four refuse reasons applies; see inspectDisk()'s note
                // on why the reason itself never reaches this page.
                s += QLatin1Char( ' ' )
                    + tr( "This disk was set up in a way this version of %1 cannot reuse, so "
                          "they cannot be kept." )
                          .arg( DiskModel::productName() );
            }
        }
    }
    else if ( e.partitions <= 0 )
    {
        s = e.contents.isEmpty() ? tr( "Everything on this disk will be deleted." )
                                 : tr( "This disk is empty." );
    }
    else
    {
        // The disk's own first partition name, which is what the row above already showed. Naming
        // it is the difference between "3 partitions will be deleted" and a sentence somebody
        // recognises as their computer. Taken from the entry rather than parsed back out of
        // `contents`, which is assembled and translated.
        const QString& first = e.firstPartition;
        s = first.isEmpty()
            ? tr( "%n partition(s) will be deleted.", "erase warning", e.partitions )
            : tr( "%n partition(s) will be deleted, including %1.", "erase warning", e.partitions ).arg( first );
    }
    if ( e.removable )
    {
        // One line, not a second checkbox (plan/24, Q2). Installing onto an external disk is a
        // real thing to want; installing onto the stick next to the one you booted from is not,
        // and the difference is worth a sentence rather than a wall.
        s += QLatin1Char( ' ' ) + tr( "This is a removable disk." );
    }
    return s;
}

QString
DiskConfig::selectedNode() const
{
    return m_model->isInstallable( m_currentIndex ) ? m_model->entries().at( m_currentIndex ).node : QString();
}

QString
DiskConfig::selectedDiskTitle() const
{
    if ( !m_model->isInstallable( m_currentIndex ) )
    {
        return {};
    }
    const DiskModel::Entry& e = m_model->entries().at( m_currentIndex );
    // rowTitle and the node, for the confirmation dialog: the name the user picked the disk by
    // and the identifier the person who already knows which one they want reads — the same two
    // things the row shows side by side, so the dialog cannot name the disk differently from the
    // list above it.
    return DiskModel::rowTitle( e ) + QLatin1String( " (" ) + e.node + QLatin1Char( ')' );
}

QString
DiskConfig::confirmTitle() const
{
    return keeping() ? tr( "Reinstall on this disk?" ) : tr( "Erase this disk?" );
}

QString
DiskConfig::confirmAcceptLabel() const
{
    return keeping() ? tr( "Reinstall" ) : tr( "Erase and install" );
}

QString
DiskConfig::confirmSubtitle() const
{
    // The whole line, composed here rather than in the QML: the disk by the name the row used,
    // then the loss summary — the same two sentences the page below the dialog already says, so
    // the dialog cannot introduce a second name for the disk — with the generic sentence for the
    // case where there is nothing composed to say (plan/27 §1).
    const QString title = selectedDiskTitle();
    const QString loss = lossSummary();
    if ( !title.isEmpty() && !loss.isEmpty() )
    {
        return tr( "%1 — %2" ).arg( title, loss );
    }
    return tr( "Everything on the selected disk will be erased." );
}

QString
DiskConfig::prettyStatus() const
{
    if ( !m_model->isInstallable( m_currentIndex ) )
    {
        return {};
    }
    const DiskModel::Entry& e = m_model->entries().at( m_currentIndex );
    const auto* branding = Calamares::Branding::instance();
    const QString product = branding ? branding->string( Calamares::Branding::VersionedName ) : DiskModel::productName();
    // The summary page's job is to name the disk one last time, in the same words the user picked
    // it by — rowTitle rather than e.title, so a disk the row named "VirtIO disk" is not suddenly
    // nameless on the summary: one composer, and the two cannot disagree.
    if ( keeping() )
    {
        return tr( "Reinstall %3 on %1 (%2), keeping its accounts, files, apps and settings." )
            .arg( DiskModel::rowTitle( e ), e.node, product );
    }
    return tr( "Erase %1 (%2) and install %3 on it." ).arg( DiskModel::rowTitle( e ), e.node, product );
}

void
DiskConfig::publish( Calamares::GlobalStorage* gs ) const
{
    if ( !gs )
    {
        return;
    }
    // The whole contract with `disksetup`, and it is deliberately FOUR keys now (plan/33 §6
    // added diskKeepData). The job does not need to know what the page decided about anything
    // else, and the page does not get to describe a disk layout that does not exist yet.
    gs->insert( QStringLiteral( "diskDevice" ), selectedNode() );
    // NOT nextEnabled(), which since plan/26 answers "may the button be pressed" (a disk alone)
    // rather than "was the erase agreed to". Spelled out here as the old gate so the job's
    // re-check keeps meaning what it has always meant: a selected, installable disk AND the
    // dialog's answer. onLeave() publishes on the way back too, where the answer is false — the
    // forward leave that reaches the exec phase is always the one that followed an accept.
    gs->insert( QStringLiteral( "diskConfirmed" ),
                m_model->isInstallable( m_currentIndex ) && m_confirmed );
    // RESERVED, and false in every build that has this comment in it (plan/24 §7). It is written
    // rather than omitted so that the key's absence never has to mean two things — "this medium
    // has no encryption" and "an older page forgot to say".
    gs->insert( QStringLiteral( "diskEncrypt" ), false );
    // keepAvailable() AND THE TICK, not m_keepData alone: a value left over from a disk that
    // offered it, still true after the selection moved to one that does not, must never reach
    // the job as "keep". disksetup re-derives the same verdict itself before it believes this
    // (plan/33 §6) — this key only tells it which of its two paths to take.
    gs->insert( QStringLiteral( "diskKeepData" ), keeping() );
}

void
DiskConfig::retranslate()
{
    m_model->retranslated();
    emit retranslated();
    emit planChanged();
}

#include "moc_DiskConfig.cpp"
