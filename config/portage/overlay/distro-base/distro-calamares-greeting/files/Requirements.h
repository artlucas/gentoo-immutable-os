/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The six checks the greeting page reports (plan/23 §3, and plan/22 §3a for the history).
 *
 * WHY THIS EXISTS AT ALL, given that Calamares ships GeneralRequirements. Two reasons, and the
 * second one is the interesting one.
 *
 * 1. Dropping the stock `welcome` module means dropping its checker with it: a requirement is
 *    contributed by a MODULE (Module::checkRequirements), so the module that draws the verdict
 *    has to be the module that owns the checks. That was the language module until plan/23 split
 *    the greeting out of it; it is this one now, and the two moved together for exactly this
 *    reason.
 *
 * 2. ONE OF UPSTREAM'S SIX DOES NOT RUN ON THIS MEDIUM, AND SAYS SO ONLY IN THE LOG. The ebuild
 *    configures Calamares with -DCMAKE_DISABLE_FIND_PACKAGE_LIBPARTED=ON, which makes
 *    find_package(LIBPARTED) fail in src/modules/welcome/CMakeLists.txt, which adds
 *    -DWITHOUT_LIBPARTED, which reaches GeneralRequirements.cpp:357:
 *
 *        // Warn, but also drop the required bit because otherwise installation
 *        // will be impossible (because the check always returns false).
 *        m_entriesToCheck.removeAll( "storage" );
 *        m_entriesToRequire.removeAll( "storage" );
 *
 *    So `requiredStorage: 32.0` — the number greeting.conf argues for out of the ESP, both root
 *    slots and /var — had never been enforced here. There was no disk row on the page and nothing
 *    blocking Next; a 16 GiB target reached the partition step before anything noticed. The
 *    storage check below is the one that makes the page's verdict true, and it is why there is
 *    no #ifdef anywhere in this file: inheriting the escape hatch would re-open the hole in
 *    silence, which is exactly how it stayed open.
 *
 * EVERY CHECK IS sysfs, POSIX OR PUBLIC libcalamares. Nothing here needs libparted, kpmcore or
 * UPower — see the note on checkHasPower() for why the last one is a deliberate subtraction and
 * not an omission.
 *
 * BOTH OF EACH ENTRY'S TEXTS ARE FUNCTIONS, for upstream's reason and not by imitation: a check
 * runs once and its result is then re-read on every language change, so a string formatted at
 * check time would keep the first language's words and the first language's digit grouping for
 * the rest of the session. The numbers are captured; the formatting happens when asked.
 */
#pragma once

#include "modulesystem/Requirement.h"

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>

class Requirements : public QObject
{
    Q_OBJECT

public:
    explicit Requirements( QObject* parent = nullptr );

    void setConfigurationMap( const QVariantMap& configurationMap );

    /*! Runs every configured check and returns the list Calamares' RequirementsModel wants. That
     *  model is the only consumer: it drives satisfiedMandatory() — and therefore Next — and it is
     *  what the vendored results list draws. There is deliberately no second, structured accessor
     *  here; the page had one while it drew its own two-column grid, and a public getter nothing
     *  reads is a claim about the design that stops being true without anything failing. */
    Calamares::RequirementsList checkRequirements();

private:
    /*! Bytes on the largest block device that is NOT the one this medium booted from.
     *
     *  Returns 0 when there is no such device. The exclusion is the same rule the disk picker
     *  applies — PartUtils::getDevices( WritableOnly ) drops whatever holds '/' — so the page and
     *  the picker cannot disagree about which disks exist, which they would if this counted the
     *  stick the installer is running from.
     */
    static qint64 largestInstallableDiskB();
    static bool batteryExists();
    static bool onMainsPower();

    QStringList m_toCheck;
    QStringList m_toRequire;
    /*! Set when the configuration map could not be read as this module expects it. A page in this
     *  state must not say yes: checkRequirements() emits a failing row of its own saying so, and
     *  every other row reports its verdict as before. plan/24 §11 is the failure this prevents. */
    bool m_configBroken = false;
    /*! Decimal GB, not GiB — the unit a disk's vendor prints on it, and the unit the disk page
     *  speaks (plan/24 §3). Rendered from build.conf's MIN_INSTALL_DISK_GB. */
    double m_requiredStorageGB = 0.0;
    /*! GiB, because memory really is sold in binary multiples. See memoryBytes(). */
    double m_requiredRamGiB = 0.0;
};
