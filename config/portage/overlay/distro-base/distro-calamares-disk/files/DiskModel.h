/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The machine's disks, as a list model (plan/24).
 *
 * EVERY DISK IS A ROW, including the ones that cannot be installed onto. "Why is my disk not in
 * this list?" is a question a picker should answer on screen rather than through a support call,
 * and one of the answers — *because the installer is running from it* — is the single most
 * important sentence on the page.
 *
 * A FILE OF ITS OWN, and that is not an aesthetic choice. A Qt translation context IS a class
 * name, and scripts/lib/check-translations.py (check 5, plan/23 §3) resolves a context to the
 * .cpp/.h whose stem matches it. A DiskModel that said its strings inside DiskConfig.cpp would
 * put the context DiskModel in a file called DiskConfig, and every one of those strings would
 * silently stay English the first time anybody translated this page.
 */
#pragma once

#include <QAbstractListModel>
#include <QString>
#include <QVector>

class DiskModel : public QAbstractListModel
{
    Q_OBJECT

public:
    /*! Why a disk cannot be installed onto. STORED RATHER THAN FORMATTED: the enumeration runs
     *  once and its text is re-read on every language change, so a string built at scan time
     *  would keep the first language's words for the rest of the session. Same reasoning as the
     *  greeting page's requirement entries, which keep both of their texts as functions. */
    enum class Block
    {
        None = 0,
        /*! The disk this installer is running from. The one exclusion that protects data. */
        LiveMedium,
        /*! Smaller than minimumDiskSize — build.conf's MIN_INSTALL_DISK_GB. */
        TooSmall,
        /*! The kernel says read-only (/sys/block/<d>/ro). Card-reader lock switches, mostly. */
        ReadOnly,
    };
    Q_ENUM( Block )

    /*! Whether this disk already holds an install of this distro, and whether disksetup can
     *  keep it (plan/33 §4). Set in DiskConfig::enumerate() from `disk-layout inspect`, run
     *  once per eligible disk — the same helper the job re-runs before it writes anything, so
     *  the page and the job cannot disagree about a disk. */
    enum class Keep
    {
        None = 0,  //!< Not recognisably an install of this distro. The page does what it always did.
        Offered,   //!< An install this build's disksetup can keep.
        Refused,   //!< An install, but this build cannot reuse it (`inspect`'s `refuse`, or no ext4).
    };
    Q_ENUM( Keep )

    enum Roles
    {
        /*! What the user reads first: "Samsung SSD 990 PRO 1TB", from sysfs — or the bus's own
         *  name when the kernel reports no model (rowTitle, below). */
        TitleRole = Qt::DisplayRole,
        /*! "/dev/nvme0n1". Shown small, for the people who already know which disk they want. */
        NodeRole = Qt::UserRole + 1,
        /*! The size as its vendor prints it — "1.0 TB", decimal (plan/24 §3). */
        SizeTextRole,
        /*! The second line: what is on the disk now, or why it cannot be used. */
        ContentsRole,
        BlockedRole,
        RemovableRole,
    };

    struct Entry
    {
        QString node;        //!< /dev/nvme0n1
        QString kernelName;  //!< nvme0n1, the /sys/block directory
        /*! "Samsung SSD 990 PRO 1TB". EMPTY when the kernel reports no model, which is not an
         *  error state: virtio disks never have one, and the row then says the bus's name
         *  (rowTitle) rather than falling back to the node it already shows small. */
        QString title;
        /*! The bus as /sys names it — "nvme", "virtio", "scsi" — from the device's subsystem
         *  link. Kept raw rather than said as a word at scan time, for the reason Block's texts
         *  give: a word built once would keep the first language's spelling for the session. */
        QString transport;
        qint64 bytes = 0;
        bool removable = false;
        int partitions = 0;
        /*! "EFI, Windows (NTFS, 420 GB), Recovery" — joined from lsblk. Empty when lsblk could
         *  not be asked, which the row reports rather than hiding. */
        QString contents;
        /*! The first partition's name on its own, for the sentence under the checkbox. Kept
         *  apart from `contents` rather than parsed back out of it: `contents` is a translated,
         *  assembled string and re-splitting it would work in English and quietly stop working
         *  in the languages that punctuate differently. */
        QString firstPartition;
        Block block = Block::None;

        /*! plan/33 §4/§5. `keep` is None for every disk that is not recognisably an install of
         *  this distro — which is most of them — so the four fields below are meaningful only
         *  when it is Offered or Refused. */
        Keep keep = Keep::None;
        /*! "0.3.0" — the highest root_<v> `inspect` found, on Offered and Refused alike; empty
         *  for None. What ContentsRole names the disk by, and what §9's sentences quote. */
        QString installedVersion;
        /*! The kept disk's ACTUAL four segment sizes, from `inspect`'s esp_mib/slot_mib/
         *  spare_mib/var_mib — the layout that is really on the disk, which need not match this
         *  build's own ESP_SIZE_MIB/ROOT_SLOT_SIZE_MIB if an earlier build used different ones.
         *  Zero unless keep is Offered. */
        qint64 keptEspBytes = 0;
        qint64 keptSlotBytes = 0;
        qint64 keptSpareBytes = 0;
        qint64 keptVarBytes = 0;
    };

    explicit DiskModel( QObject* parent = nullptr );

    void setEntries( const QVector< Entry >& entries );
    const QVector< Entry >& entries() const { return m_entries; }

    int rowCount( const QModelIndex& parent = QModelIndex() ) const override;
    QVariant data( const QModelIndex& index, int role ) const override;
    QHash< int, QByteArray > roleNames() const override;

    /*! Re-reads every row's text. Called on a language change rather than resetting the model,
     *  for the reason the language page's model records: a reset takes the ListView's
     *  currentIndex with it, and here that would silently un-choose the user's disk. */
    void retranslated();

    bool isInstallable( int row ) const;
    int installableCount() const;

    /*! DECIMAL — "1.0 TB", never "931.5 GiB" (plan/24 §3). Static because DiskConfig sizes the
     *  plan bar's segments with the same rule, and two formatters would be two answers to one
     *  question on one screen. */
    static QString formatSize( qint64 bytes );
    /*! The row's title as the user reads it: the model string when the kernel has one, the bus's
     *  generic name when it does not. THE ONE COMPOSER — the summary page names the disk through
     *  this too, so it cannot disagree with the row about which disk was chosen. */
    static QString rowTitle( const Entry& e );
    /*! "VirtIO disk", "NVMe disk", "Disk". Static for the same reason formatSize is: one name,
     *  said by the rows and by the summary, and two spellings would be two disks. */
    static QString genericTitle( const Entry& e );
    /*! The branding's product name, or a usable stand-in. Static for the same reason. */
    static QString productName();

private:
    QVector< Entry > m_entries;
};
