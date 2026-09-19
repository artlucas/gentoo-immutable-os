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
 * WHAT THE DESIGN HAND-OFF DRAWS. The mockup has four more controls than the region and zone
 * pickers: a Formats picker, a Measurement picker, "set the time automatically over the network",
 * and a 24-hour clock switch. Two of them are here now and two are still not:
 *
 *   * Formats and Measurement are LC_TIME / LC_NUMERIC / LC_MEASUREMENT, and offering them for a
 *     locale the image did not compile is exactly the bug plan/22 §6 spent a page fixing. The
 *     image carries the nine locales in config/languages.conf and nothing else.
 *   * The 24-hour clock was on that second list, and on a DIFFERENT argument from the other two:
 *     as the design draws it, it is a switch on this page that writes a Plasma locale setting on
 *     the installed machine, and nothing in this pipeline writes one. That is still true and the
 *     switch is still not here. What plan/30 added instead is a CONFIGURATION key — twelveHour in
 *     modules/location.conf, on by default — because the page has its own clock on it and the
 *     dialog has its own time field, and how THOSE read was never Plasma's business. It is the
 *     distribution's answer, not a question put to the user, so it is a conf key and not a
 *     control: a switch the user can move is the thing that would need wiring to outlive the
 *     page, and a build-time default does not.
 *   * Automatic time WAS in that second list, on exactly that argument, until the wiring was
 *     built (plan/29). It is here now because all three of its ends exist: build.conf's
 *     NTP_SERVERS renders a FallbackNTP= drop-in that every profile ships, systemd-timesyncd is
 *     enabled in the vendor preset, and `localesetup` carries the user's answer into the
 *     installed system — masking timesyncd there when the answer is no, so that the checkbox
 *     means the same thing on the machine as it did on the page.
 *
 * THE TWO ACTIONS THIS PAGE TAKES ON THE RUNNING MACHINE, and they are the only two on the whole
 * installer that change the medium rather than describing the target. Calamares runs as root
 * (the autostart is `pkexec calamares`), so `timedatectl` is available and authorised:
 *
 *   * checking the box runs `timedatectl set-ntp true` and then watches NTPSynchronized until it
 *     says yes, which is the only honest way to report "the clock is set from the network" —
 *     asking for a sync and announcing success is a claim about a server that may not have
 *     answered;
 *   * the Set-date-and-time dialog runs `timedatectl set-time`, which systemd also writes
 *     through to the RTC, so the machine this medium is about to install onto starts from the
 *     clock the user just corrected.
 *
 * Both are refused by systemd in the other's state — set-time fails while NTP is on — so the
 * button is disabled while the box is checked rather than left to fail and explain.
 */
#pragma once

#include "locale/TimeZone.h"

#include <QObject>
#include <QString>
#include <QStringList>
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

    /*! Whether this page reads and takes a 12-hour clock (plan/30 §3). From
     *  modules/location.conf, defaulting to TRUE — the distribution's answer and not the user's,
     *  which is why it is a key and not a switch.
     *
     *  CONSTANT: it is read once in setConfigurationMap() and nothing can move it afterwards. A
     *  NOTIFY with nothing to emit it is a signal the QML would connect to and wait on forever.
     *
     *  IT IS NOT A QLocale QUESTION, and that is the thing to hold on to. clockTime() used to ask
     *  QLocale for a ShortFormat, on the argument that whether a clock reads 13:45 or 1:45 PM is a
     *  property of the language chosen a page earlier and Qt already knows. Qt does know — it just
     *  does not agree with the image: a French installer would draw a 24-hour clock on a
     *  distribution that had decided otherwise, and the page would be the only screen in the
     *  installer where a build-time decision was overridden by the keyboard layout's country. */
    Q_PROPERTY( bool twelveHour READ twelveHour CONSTANT )
    /*! The two words a 12-hour clock needs, from QLocale — so they follow the language the user
     *  picked on the page before this one rather than being two more strings to translate nine
     *  times. Empty, both of them, when the flag is off. */
    Q_PROPERTY( QString amLabel READ amLabel NOTIFY retranslated )
    Q_PROPERTY( QString pmLabel READ pmLabel NOTIFY retranslated )

    /*! Whether the clock is set from the network. WRITEABLE from QML, because checking the box
     *  IS the action: setNetworkTime() runs timedatectl and starts the watch. */
    Q_PROPERTY( bool networkTime READ networkTime WRITE setNetworkTime NOTIFY networkTimeChanged )
    /*! "off" | "busy" | "ok" | "failed" | "unavailable" — a string rather than an enum so the QML
     *  can compare it without a registered metatype, the way every other state on these pages is
     *  passed. It is what the status line is COLOURED by; syncStatus is what it says. */
    Q_PROPERTY( QString syncState READ syncState NOTIFY syncChanged )
    Q_PROPERTY( QString syncStatus READ syncStatus NOTIFY syncChanged )
    /*! False while the network sets the clock: systemd refuses `timedatectl set-time` outright
     *  when NTP is on, so the button is disabled rather than left to fail and then explain. */
    Q_PROPERTY( bool canSetTime READ canSetTime NOTIFY networkTimeChanged )
    /*! What went wrong in the set-time dialog, or "" — bound to the dialog's message line and
     *  cleared every time it opens. */
    Q_PROPERTY( QString setTimeError READ setTimeError NOTIFY setTimeErrorChanged )

    Q_PROPERTY( QString pageTitle READ pageTitle NOTIFY retranslated )
    Q_PROPERTY( QString pageLede READ pageLede NOTIFY retranslated )
    Q_PROPERTY( QString regionLabel READ regionLabel NOTIFY retranslated )
    Q_PROPERTY( QString zoneLabel READ zoneLabel NOTIFY retranslated )
    Q_PROPERTY( QString networkTimeLabel READ networkTimeLabel NOTIFY retranslated )
    Q_PROPERTY( QString networkTimeHint READ networkTimeHint NOTIFY retranslated )
    Q_PROPERTY( QString setTimeLabel READ setTimeLabel NOTIFY retranslated )
    Q_PROPERTY( QString setTimeTitle READ setTimeTitle NOTIFY retranslated )
    /*! NOTIFY tick, not retranslated: this sentence names the chosen zone, so it has to be
     *  re-read when the zone moves as well as when the language does — and tick is emitted
     *  for both, plus once a second, which costs a string nobody is looking at. */
    Q_PROPERTY( QString setTimeBody READ setTimeBody NOTIFY tick )
    Q_PROPERTY( QString setTimeDateLabel READ setTimeDateLabel NOTIFY retranslated )
    Q_PROPERTY( QString setTimeTimeLabel READ setTimeTimeLabel NOTIFY retranslated )
    /*! The hints under the two fields carry a WORKED EXAMPLE rather than a format string:
     *  "2026-09-18" tells a reader what to type and "yyyy-MM-dd" tells a programmer. They are
     *  recomputed on every retranslate, which is also every midnight this page is open. */
    Q_PROPERTY( QString setTimeDateHint READ setTimeDateHint NOTIFY tick )
    Q_PROPERTY( QString setTimeTimeHint READ setTimeTimeHint NOTIFY tick )
    /*! The label over the dialog's AM/PM select. It exists for a layout reason as much as a
     *  reading one — see the note beside the control in Location.qml — and it is translated
     *  rather than left as the two letters, because the languages that do not write "AM" have a
     *  word for the same idea. */
    Q_PROPERTY( QString setTimeMeridiemLabel READ setTimeMeridiemLabel NOTIFY retranslated )
    Q_PROPERTY( QString setTimeConfirm READ setTimeConfirm NOTIFY retranslated )
    Q_PROPERTY( QString setTimeCancel READ setTimeCancel NOTIFY retranslated )

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

    bool networkTime() const { return m_networkTime; }
    void setNetworkTime( bool on );
    QString syncState() const { return m_syncState; }
    QString syncStatus() const { return m_syncStatus; }
    bool canSetTime() const { return !m_networkTime; }
    QString setTimeError() const { return m_setTimeError; }

    QString networkTimeLabel() const { return tr( "Set the time automatically over the network" ); }
    QString networkTimeHint() const
    {
        return tr( "The installed system keeps doing this. Turn it off to set the clock by hand." );
    }
    QString setTimeLabel() const { return tr( "Set date and time…" ); }
    QString setTimeTitle() const { return tr( "Set the date and time" ); }
    QString setTimeBody() const
    {
        return tr( "This sets this machine's clock now, in %1. The system you install starts from "
                   "the same clock." )
            .arg( zoneId() );
    }
    QString setTimeDateLabel() const { return tr( "Date" ); }
    QString setTimeTimeLabel() const { return tr( "Time" ); }
    QString setTimeDateHint() const { return tr( "Year-month-day, as in %1" ).arg( editDate() ); }
    QString setTimeTimeHint() const
    {
        return m_twelveHour ? tr( "Hours and minutes, as in %1" ).arg( editTime() )
                            : tr( "A 24-hour clock, as in %1" ).arg( editTime() );
    }
    QString setTimeMeridiemLabel() const { return tr( "AM/PM" ); }
    QString setTimeConfirm() const { return tr( "Set" ); }
    bool twelveHour() const { return m_twelveHour; }
    QString amLabel() const;
    QString pmLabel() const;
    QString setTimeCancel() const { return tr( "Cancel" ); }

    /*! The dialog's two fields, pre-filled with now IN THE CHOSEN ZONE.
     *
     * A FIXED FORMAT, NOT QLocale's, and this is the one place on the page where that is the
     * right answer. Everything else here — the clock, the date under it — is READ, and a reader
     * is best served by their own conventions. These two are TYPED, and a typed date in a
     * locale's short form is the ambiguity nobody can see: 03/04/2026 is two different days on
     * two sides of an ocean, and the field cannot ask which one was meant. So the dialog shows
     * and takes one unambiguous shape, and the hint under each field is an example of it.
     */
    Q_INVOKABLE QString editDate() const;
    Q_INVOKABLE QString editTime() const;
    /*! Which half of the day the pre-filled time is in: 0 for AM, 1 for PM, and -1 when the
     *  12-hour flag is off. The dialog's select takes this as its starting index. */
    Q_INVOKABLE int editMeridiem() const;

    /*! Sets this machine's clock from the dialog's two fields, which are read AS TIMES IN THE
     *  CHOSEN ZONE — the page shows a clock in that zone, so a person correcting it is correcting
     *  what they can see. Returns true on success; on failure setTimeError says what happened. */
    /*! THE MERIDIEM CROSSES AS AN INDEX, NOT AS A WORD. The two labels come out of QLocale so
     *  that they follow the user's language; a C++ side that then parsed the string it had just
     *  handed out would be re-deriving, in one language, something it already knew — and would
     *  break the day a translation of "PM" collided with something else. -1 means the flag is
     *  off and `time` is already on a 24-hour clock. */
    Q_INVOKABLE bool applySystemTime( const QString& date, const QString& time, int meridiem );
    /*! Clears setTimeError. Called when the dialog opens, so that yesterday's complaint is not
     *  the first thing in it. */
    Q_INVOKABLE void clearSetTimeError();
    /*! Applies whatever `networkTime` currently says to the running machine, and starts the watch
     *  if it says yes. Called from LocationViewStep::onActivate(): the box is checked when the
     *  page opens, so the page's first act is the one it is promising. */
    Q_INVOKABLE void applyNetworkTime();

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
    void networkTimeChanged();
    void syncChanged();
    void setTimeErrorChanged();

private:
    /*! Clamps `zone` to one the current region actually has, and picks the region's first
     *  otherwise. Called whenever the region moves. */
    void clampZone();

    /*! `timedatectl <args>`, run to completion. SYNCHRONOUSLY, which for a page is usually the
     *  wrong shape and here is the right one: every call is a D-Bus round trip to timedated on
     *  the same machine and returns in milliseconds. The thing that actually TAKES time — waiting
     *  for a time server to answer — is not a command at all; it is the poll below, which is a
     *  timer. Writing the fast calls asynchronously would buy nothing and cost the page a state
     *  machine per button.
     *
     * Returns false if timedatectl is missing, crashed or exited non-zero; `out` gets its merged
     * output either way, because that is where systemd puts the reason. */
    bool timedatectl( const QStringList& args, QString* out = nullptr );

    /*! Starts the watch on NTPSynchronized. Announcing "the clock is set from the network" the
     *  instant set-ntp returns would be a claim about a server that has not been asked yet. */
    void beginSyncWatch();
    void pollSync();
    void setSyncState( const QString& state, const QString& server = QString() );
    /*! Rebuilds m_syncStatus from m_syncState and m_syncServer — on a state change and on a
     *  language change, which is why the composed string is stored rather than the pieces. */
    void composeSyncStatus();
    void setSetTimeError( const QString& message );

    Calamares::Locale::RegionsModel* m_regions;
    Calamares::Locale::ZonesModel* m_zones;
    Calamares::Locale::RegionalZonesModel* m_regionalZones;

    QString m_region;
    QString m_zone;
    QTimer* m_clock;

    /*! modules/location.conf's `twelveHour`, defaulting to TRUE — see the Q_PROPERTY. */
    bool m_twelveHour = true;

    bool m_networkTime = true;
    QString m_syncState = QStringLiteral( "off" );
    QString m_syncStatus;
    QString m_syncServer;
    QString m_setTimeError;
    QTimer* m_poll;
    /*! How many one-second polls are left before the watch gives up. Twenty, because timesyncd
     *  gets its first answer in under a second on a working network and a DNS lookup that has to
     *  time out takes most of the rest — and because a status line that never resolves is the one
     *  outcome worse than "no time server answered". */
    int m_pollsLeft = 0;
};
