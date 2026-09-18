/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The location page's state (plan/28 §6).
 *
 * WHAT THIS REPLACES, AND WHAT THE OLD PAGE'S OWN CONFIGURATION ASKED FOR. Calamares' `locale`
 * module draws a world map, a region/zone pair of combo boxes, and a button that opens
 * LCLocaleDialog — a list of every locale in /usr/share/i18n/SUPPORTED, rendered as raw codes.
 * plan/22 §6 cut that list from five hundred entries to nine by deleting the file stage 50 now
 * removes, and ended with the honest note that the remaining nine are still codes behind a button
 * with no key that relabels them, because the dialog is upstream's. modules/locale.conf closed
 * with:
 *
 *     "removing the last of them means replacing this page — a separate module and a separate
 *      decision, since timezone is what this page is really for (plan/22 §8)."
 *
 * This is that module, and it takes the note at its word: THE PAGE ASKS FOR A PLACE. The language
 * page already chose the language, `imageidentity` already writes /etc/locale.conf from it and
 * refuses a locale the image cannot load, so a second locale question here would be the same
 * question asked worse.
 *
 * THE MODELS ARE CALAMARES' OWN. libcalamares/locale/TimeZone.h exports RegionsModel, ZonesModel
 * and RegionalZonesModel, and they are INSTALLED headers — so this module parses no tzdata, ships
 * no table, and gets upstream's translations of every region name for free. That is the same
 * finding that retired the greeting page's vendored widgets: the thing worth copying was already
 * in the library.
 *
 * WHAT THE DESIGN HAND-OFF DRAWS AND THIS PAGE DELIBERATELY DOES NOT. The mockup has four more
 * controls: a Formats picker, a Measurement picker, "set the time automatically over the
 * network", and a 24-hour clock switch. None of them is implemented, and none is forgotten:
 *
 *   * Formats and Measurement are LC_TIME / LC_NUMERIC / LC_MEASUREMENT, and offering them for a
 *     locale the image did not compile is exactly the bug plan/22 §6 spent a page fixing. The
 *     image carries the nine locales in config/languages.conf and nothing else.
 *   * Automatic time and the 24-hour clock are settings on the INSTALLED system that nothing in
 *     this pipeline writes — no timesyncd drop-in, no Plasma locale config. A switch with no
 *     wiring behind it is worse than no switch: it is a promise the first boot breaks.
 *
 * So the page draws the two questions it can answer and a clock that shows what answering them
 * means. If the plumbing for the others is ever built, the controls belong here.
 */
#pragma once

#include "locale/TimeZone.h"

#include <QObject>
#include <QString>
#include <QVariantMap>

class QTimer;

class LocationConfig : public QObject
{
    Q_OBJECT

    Q_PROPERTY( QAbstractItemModel* regions READ regionsModel CONSTANT )
    /*! The zones IN the current region — a RegionalZonesModel, which is a proxy whose `region`
     *  property this class keeps in step with `region` below. */
    Q_PROPERTY( QAbstractItemModel* zones READ zonesModel CONSTANT )

    Q_PROPERTY( QString region READ region WRITE setRegion NOTIFY locationChanged )
    Q_PROPERTY( QString zone READ zone WRITE setZone NOTIFY locationChanged )

    /*! "America/New_York", for the badge. The separator is a path separator and not a word, so
     *  this is composed rather than translated. */
    Q_PROPERTY( QString zoneId READ zoneId NOTIFY locationChanged )
    /*! The chosen zone's abbreviation and offset — "EDT · UTC−4" — computed from Qt's own tz
     *  database rather than a table of our own. */
    Q_PROPERTY( QString offsetText READ offsetText NOTIFY tick )
    /*! The time and date IN THE CHOSEN ZONE, which is the whole point of showing a clock on this
     *  page: it is the one control whose effect a person can check by looking at it. */
    Q_PROPERTY( QString clockTime READ clockTime NOTIFY tick )
    Q_PROPERTY( QString clockDate READ clockDate NOTIFY tick )

    Q_PROPERTY( QString pageTitle READ pageTitle NOTIFY retranslated )
    Q_PROPERTY( QString pageLede READ pageLede NOTIFY retranslated )
    Q_PROPERTY( QString regionLabel READ regionLabel NOTIFY retranslated )
    Q_PROPERTY( QString zoneLabel READ zoneLabel NOTIFY retranslated )

public:
    explicit LocationConfig( QObject* parent = nullptr );

    void setConfigurationMap( const QVariantMap& configurationMap );

    QAbstractItemModel* regionsModel() const;
    QAbstractItemModel* zonesModel() const;

    QString region() const { return m_region; }
    void setRegion( const QString& region );
    QString zone() const { return m_zone; }
    void setZone( const QString& zone );

    QString zoneId() const;
    QString offsetText() const;
    QString clockTime() const;
    QString clockDate() const;

    QString pageTitle() const { return tr( "Where are you?" ); }
    QString pageLede() const
    {
        return tr( "Your location sets the clock and the date. The hardware clock is kept in UTC, "
                   "and you can change this later in Settings." );
    }
    QString regionLabel() const { return tr( "Region" ); }
    QString zoneLabel() const { return tr( "Zone" ); }

    /*! What the summary page shows. */
    QString prettyStatus() const;

    /*! Writes locationRegion and locationZone — UPSTREAM'S KEY NAMES, because the job that reads
     *  them is ours but the contract is not this module's to rename, and anything else in
     *  Calamares that reads a location reads those two. */
    void publish() const;

public slots:
    void retranslate();

signals:
    void locationChanged();
    void tick();
    void retranslated();

private:
    /*! Clamps `zone` to one the current region actually has, and picks the region's first
     *  otherwise. Called whenever the region moves. */
    void clampZone();

    Calamares::Locale::RegionsModel* m_regions;
    Calamares::Locale::ZonesModel* m_zones;
    Calamares::Locale::RegionalZonesModel* m_regionalZones;

    QString m_region;
    QString m_zone;
    QTimer* m_clock;
};
