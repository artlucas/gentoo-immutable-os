/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The disk page's state (plan/24).
 *
 * TWO OBJECTS, THE SAME SHAPE AS THE LANGUAGE PAGE'S. DiskModel (DiskModel.h) is the machine's
 * disks — every one of them, including the ones that cannot be installed onto. This is the other
 * half: which row is chosen, whether the confirmation dialog has been answered, and the strings
 * that describe what is about to happen to that disk.
 *
 * WHY THIS PAGE EXISTS AT ALL, given that the stock `partition` module already did it. It did,
 * and what it produced was a partition editor with most of its controls removed: a device combo
 * box, one radio button and a before/after strip drawn in partition colours. Every word on it was
 * upstream's, aimed at an installer that offers manual partitioning, side-by-side installs and
 * filesystem choices — none of which this distro has. See plan/24 §1.
 *
 * WHAT THIS FILE MUST NEVER STOP DOING, and it is the one thing here that can destroy data:
 * exclude the disk the medium is running from. Until plan/24 that was free — PartUtils::
 * getDevices( WritableOnly ) drops any device holding a partition mounted at "/"
 * (core/DeviceList.cpp:178) and the stock page never saw it. We do not run that code any more, so
 * the rule is implemented here, in liveMediumDisk(), and it is the same rule the greeting page's
 * Requirements::largestInstallableDiskB() already applies to decide whether the install may start
 * at all. Two implementations of one rule, deliberately: they are in different plugins and
 * neither can include the other's header. tests/test-installer.sh asserts both still exist.
 *
 * EVERYTHING LOAD-BEARING IS sysfs. /sys/block is what decides which disks exist, how big they
 * are and which one is the medium; `lsblk` is asked afterwards, and only for the second line of
 * each row — what is on the disk now. If it is missing or its JSON is unreadable the page still
 * works and the rows say so. A disk picker that cannot enumerate disks because a helper binary
 * moved is a worse failure than a disk picker with a vaguer second line.
 */
#pragma once

#include "DiskModel.h"

#include <QObject>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QVector>

namespace Calamares
{
class GlobalStorage;
}

class DiskConfig : public QObject
{
    Q_OBJECT

public:
    // ---- the list ----------------------------------------------------------------------------
    Q_PROPERTY( QAbstractItemModel* disks READ disksModel CONSTANT )
    /*! The selected row, or -1. The QML's ListView owns the highlight and pushes its currentIndex
     *  here, then puts back whatever this setter accepts — the language page's pattern, and for
     *  the same reason: two sources of truth for a selection is how a page ends up drawing one
     *  row as chosen while installing onto another. Here that would be the wrong disk. */
    Q_PROPERTY( int currentIndex READ currentIndex WRITE setCurrentIndex NOTIFY currentIndexChanged )
    /*! The confirmation dialog's answer, and it lives for one press of Next (plan/26 §1). False
     *  whenever the page is entered — DiskViewStep::onLeave() withdraws it on the way out — so
     *  every press of the window's Next that would leave this page asks the question again, and
     *  isAtEnd() is what makes it ask: while this is false, ViewManager::next() calls the step's
     *  next() instead of advancing, and next() is what opens the dialog. Also reset by a disk
     *  change or a rescan, belt and braces: no answer should outlive the thing it was about. */
    Q_PROPERTY( bool confirmed READ confirmed WRITE setConfirmed NOTIFY confirmedChanged )
    Q_PROPERTY( bool nextEnabled READ nextEnabled NOTIFY nextEnabledChanged )
    /*! The selected disk, named the way the row names it (DiskModel::rowTitle, plus the device
     *  node), so the confirmation dialog says WHICH disk. Empty when nothing is selected. */
    Q_PROPERTY( QString selectedDiskTitle READ selectedDiskTitle NOTIFY currentIndexChanged )

    Q_PROPERTY( int diskCount READ diskCount NOTIFY disksChanged )
    Q_PROPERTY( int installableCount READ installableCount NOTIFY disksChanged )

    /*! The question at the top, and the sentence under it. Properties rather than qsTr() in the
     *  QML because they change with the machine as well as with the language: a computer with one
     *  disk is told it has one disk, and a computer with none is told what would fix it. */
    Q_PROPERTY( QString headline READ headline NOTIFY retranslated )
    Q_PROPERTY( QString subheadline READ subheadline NOTIFY retranslated )
    /*! "32 GB", for the empty state's sentence. One number, from build.conf. */
    Q_PROPERTY( QString minimumSizeText READ minimumSizeText NOTIFY retranslated )

    /*! The rest of the page's words (plan/27 §1): every string Disk.qml shows is a tr()'d
     *  property, because the builder's lupdate is built without QML support and a qsTr() in the
     *  QML has never reached the branding catalogue — the treatment plan/25 §4 established for
     *  the applications page. confirmSubtitle composes the confirmation dialog's line from
     *  selectedDiskTitle and lossSummary in C++ — a format string with two substituted strings
     *  is three translations' worth of moving parts for one property — so it depends on the
     *  selection as well as on the language, and setCurrentIndex() re-emits retranslated() for
     *  it the way rescan() always has for the headline. */
    Q_PROPERTY( QString checkAgainLabel READ checkAgainLabel NOTIFY retranslated )
    /*! The badge a row that cannot be installed onto wears (plan/28). Until the page was
     *  repainted, "blocked" was drawn as nothing but reduced opacity — which says "unavailable"
     *  to somebody who already suspects it and says nothing at all to anybody else, least of all
     *  to a screen reader. It is the one word this page gained from the design system's row
     *  layout, and installable rows deliberately get no badge in return: the installer does not
     *  rank disks, and a "Recommended" chip would be an opinion it has not got. */
    Q_PROPERTY( QString notEligibleLabel READ notEligibleLabel NOTIFY retranslated )
    Q_PROPERTY( QString noDisksText READ noDisksText NOTIFY retranslated )
    Q_PROPERTY( QString noDisksMinimumText READ noDisksMinimumText NOTIFY retranslated )
    Q_PROPERTY( QString layoutSummaryLabel READ layoutSummaryLabel NOTIFY retranslated )
    Q_PROPERTY( QString encryptLabel READ encryptLabel NOTIFY retranslated )
    Q_PROPERTY( QString notYetAvailableText READ notYetAvailableText NOTIFY retranslated )
    Q_PROPERTY( QString confirmTitle READ confirmTitle NOTIFY retranslated )
    Q_PROPERTY( QString confirmSubtitle READ confirmSubtitle NOTIFY retranslated )
    Q_PROPERTY( QString cancelLabel READ cancelLabel NOTIFY retranslated )
    Q_PROPERTY( QString confirmAcceptLabel READ confirmAcceptLabel NOTIFY retranslated )

    /*! The bar: a list of { label, sizeText, bytes } in on-disk order, or empty when nothing is
     *  selected. The QML gives them colours; the sizes and the order are the layout's. */
    Q_PROPERTY( QVariantList plan READ plan NOTIFY planChanged )
    /*! "3 partitions will be deleted, including Windows (NTFS, 420 GB)." The sentence under the
     *  plan bar and inside the confirmation dialog, built from what the row already read. */
    Q_PROPERTY( QString lossSummary READ lossSummary NOTIFY planChanged )
    /*! FALSE, and drawn anyway (plan/24 §7). The row exists, disabled, with a reason. Hiding it
     *  would mean the first person to ask about encryption asks whether it was forgotten. */
    Q_PROPERTY( bool encryptionAvailable READ encryptionAvailable CONSTANT )

    // ---- keeping what is on the disk (plan/33) --------------------------------------------
    /*! The SELECTED row already holds a recognisable install of this distro, whether or not it
     *  can actually be kept (DiskModel::Keep != None). Decides WHICH ROW Disk.qml draws in the
     *  slot the encryption row used to occupy alone — the keep row on a disk this is true for,
     *  the encryption row on every other disk — never both and never neither. */
    Q_PROPERTY( bool keepOffered READ keepOffered NOTIFY planChanged )
    /*! The selected row's install can actually be kept (== Offered rather than Refused). Gates
     *  the checkbox itself; keepOffered alone only decided which row is drawn at all. */
    Q_PROPERTY( bool keepAvailable READ keepAvailable NOTIFY planChanged )
    /*! The tick. TICKED BY DEFAULT the moment it becomes available (plan/33 §1) — the choice
     *  that cannot lose anything is the one a user has to act to leave — computed in
     *  setCurrentIndex() and ignored by the setter unless keepAvailable(). */
    Q_PROPERTY( bool keepData READ keepData WRITE setKeepData NOTIFY keepDataChanged )
    Q_PROPERTY( QString keepLabel READ keepLabel NOTIFY retranslated )
    /*! The hint beside a disabled checkbox, on a disk that holds an install this build cannot
     *  reuse (DiskModel::Keep::Refused). */
    Q_PROPERTY( QString keepUnavailableText READ keepUnavailableText NOTIFY retranslated )

    explicit DiskConfig( QObject* parent = nullptr );

    void setConfigurationMap( const QVariantMap& configurationMap );

    QAbstractItemModel* disksModel() const;
    int currentIndex() const { return m_currentIndex; }
    void setCurrentIndex( int index );
    bool confirmed() const { return m_confirmed; }
    void setConfirmed( bool confirmed );
    bool nextEnabled() const;
    int diskCount() const;
    int installableCount() const;
    QString headline() const;
    QString subheadline() const;
    QString minimumSizeText() const;
    // The words (plan/27 §1), inline for the same reason the headline is not: they are one line
    // each, and out-of-line getters would bury them. confirmSubtitle is the one composition.
    QString checkAgainLabel() const { return tr( "Check again" ); }
    QString notEligibleLabel() const { return tr( "Not eligible" ); }
    QString noDisksText() const { return tr( "No disks were found at all." ); }
    QString noDisksMinimumText() const
    {
        return tr( "Plug in a disk of at least %1 and choose Check again. These are the disks "
                   "this computer has now:" )
            .arg( minimumSizeText() );
    }
    QString layoutSummaryLabel() const { return tr( "The disk will be set up like this" ); }
    QString encryptLabel() const { return tr( "Encrypt this disk" ); }
    QString notYetAvailableText() const { return tr( "Not yet available" ); }
    // confirmTitle/confirmAcceptLabel are no longer one-liners: both now say something different
    // while keeping (plan/33 §9), so they moved out of line beside confirmSubtitle.
    QString confirmTitle() const;
    QString confirmSubtitle() const;
    QString cancelLabel() const { return tr( "Cancel" ); }
    QString confirmAcceptLabel() const;
    QString selectedDiskTitle() const;
    QVariantList plan() const;
    QString lossSummary() const;
    bool encryptionAvailable() const { return false; }

    bool keepOffered() const;
    bool keepAvailable() const;
    bool keepData() const { return m_keepData; }
    void setKeepData( bool keep );
    QString keepLabel() const { return tr( "Keep my files, apps and settings" ); }
    QString keepUnavailableText() const { return tr( "Not possible on this disk" ); }

    /*! Re-enumerate. Bound to "Check again", because plugging a disk in is the fix for the one
     *  state this page can reach with nothing to offer. */
    Q_INVOKABLE void rescan();

    /*! Ask the question the window's Next now asks (plan/26 §1). Called from
     *  DiskViewStep::next() — which ViewManager::next() reaches instead of advancing while
     *  isAtEnd() is false — and does nothing but emit confirmationRequested(); the dialog is
     *  QML's to draw, because everything else on this page is. */
    void requestConfirmation();

    /*! The dialog's "Erase and install". Sets confirmed, which flips isAtEnd(), which lets the
     *  view step complete the advance it was asked for. */
    Q_INVOKABLE void acceptConfirmation();

    /*! What the summary page shows: the disk, by the name the user picked it by. */
    QString prettyStatus() const;

    /*! The chosen device node, for the tests and for the job. */
    QString selectedNode() const;

    /*! Writes the choice into GlobalStorage. `disksetup` reads it; nothing else does.
     *
     *  ONLY THE DEVICE AND THE INTENT. It deliberately does NOT write the `partitions` list —
     *  that is a statement about what is on the disk, and until the job has written the GPT it
     *  would be a statement about a disk that does not look like that yet. imagedeploy and
     *  imagebootloader read it after `disksetup` has made it true. */
    void publish( Calamares::GlobalStorage* gs ) const;

public slots:
    void retranslate();

signals:
    void currentIndexChanged();
    void confirmedChanged();
    void confirmationRequested();
    void nextEnabledChanged();
    void disksChanged();
    void planChanged();
    void retranslated();
    void keepDataChanged();

private:
    QVector< DiskModel::Entry > enumerate() const;

    /*! Runs the layout helper against ONE disk (plan/33 §4/§5): `sfdisk --dump`, then
     *  `<layoutHelper> inspect` with the dump on stdin, then — only on a `keep` verdict — the
     *  var partition's lsblk fstype, because `inspect` is a pure text function over a partition
     *  TABLE and never looks at what is actually written to a filesystem. Sets e.keep,
     *  e.installedVersion and the four kept* sizes; leaves them at their defaults (None, empty,
     *  zero) on anything short of a full Offered verdict except where noted. Called from
     *  enumerate() only for an otherwise-installable row whose lsblk children already include a
     *  partition literally labelled "var" — the cheap gate that keeps this off every disk that
     *  obviously never ran this distro. */
    void inspectDisk( DiskModel::Entry& e ) const;

    /*! Any INSTALLABLE row the model holds offers a keep — used by subheadline(), which the
     *  disk list's own note says must depend on the machine, not on the current selection. */
    bool anyRowOffersKeep() const;

    /*! keepAvailable() AND the tick — the one condition plan() /lossSummary()/confirmTitle()/
     *  confirmAcceptLabel()/prettyStatus() all branch on (plan/33 §5). Not a Q_PROPERTY: nothing
     *  in the QML needs "is it available AND ticked" as a single value, only the two halves. */
    bool keeping() const;

    DiskModel* m_model;
    int m_currentIndex = -1;
    bool m_confirmed = false;

    /*! Decimal GB, from build.conf's MIN_INSTALL_DISK_GB through modules/disk.conf. The greeting
     *  page's requiredStorage is rendered from the same value. */
    double m_minimumDiskGB = 0.0;
    qint64 m_espBytes = 0;
    qint64 m_slotBytes = 0;

    /*! /usr/libexec/<id>-disk-layout — modules/disk.conf's `layoutHelper`, read with
     *  Calamares::getString() rather than configNumber() (plan/33 §5): the disk plugin's
     *  file-static configNumber() call-site count is pinned at five by the tests, and this is a
     *  string, not a number. Empty means no keep can ever be offered — inspectDisk() no-ops. */
    QString m_layoutHelper;
    /*! The tick (plan/33 §1). Recomputed by setCurrentIndex() on every selection, TICKED by
     *  default whenever the newly selected row offers it. */
    bool m_keepData = false;
};
