/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "LocationConfig.h"

#include "GlobalStorage.h"
#include "JobQueue.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"
#include "utils/Variant.h"

#include <QDate>
#include <QDateTime>
#include <QLocale>
#include <QProcess>
#include <QTime>
#include <QTimeZone>
#include <QTimer>

namespace
{
/*! The two typed formats the set-time dialog uses. Fixed rather than QLocale's, for the reason
 *  LocationConfig.h gives at length above editDate(): a date read back from a locale's short form
 *  is ambiguous in a way the field cannot ask about. */
const char* const kEditDateFormat = "yyyy-MM-dd";
const char* const kEditTimeFormat = "HH:mm";

/*! How long a timedatectl call is given. It is a D-Bus round trip to a service on this machine;
 *  five seconds is not a budget, it is a deadlock detector. */
constexpr int kTimedatectlTimeoutMs = 5000;

/*! The IANA id Qt wants, from the two halves this page keeps. */
QByteArray
ianaId( const QString& region, const QString& zone )
{
    if ( region.isEmpty() || zone.isEmpty() )
    {
        return {};
    }
    return ( region + QLatin1Char( '/' ) + zone ).toUtf8();
}
}  // namespace

LocationConfig::LocationConfig( QObject* parent )
    : QObject( parent )
    , m_regions( new Calamares::Locale::RegionsModel( this ) )
    , m_zones( new Calamares::Locale::ZonesModel( this ) )
    , m_regionalZones( new Calamares::Locale::RegionalZonesModel( m_zones, this ) )
    , m_clock( new QTimer( this ) )
{
    CALAMARES_RETRANSLATE_SLOT( &LocationConfig::retranslate );

    // ONE SECOND, and the clock is the reason this page has a timer at all: it is the only
    // control on the installer whose effect can be checked by looking at it, and a clock that
    // only moved when something else did would be a picture of a clock.
    m_clock->setInterval( 1000 );
    connect( m_clock, &QTimer::timeout, this, &LocationConfig::tick );
    m_clock->start();

    // The sync watch. Not started here: it runs only between "the box was checked" and "a time
    // server answered, or twenty seconds went by without one".
    m_poll = new QTimer( this );
    m_poll->setInterval( 1000 );
    connect( m_poll, &QTimer::timeout, this, &LocationConfig::pollSync );

    composeSyncStatus();
}

void
LocationConfig::setConfigurationMap( const QVariantMap& configurationMap )
{
    // The default pin, before the user chooses. location.conf names a PLACE (America/Toronto) and
    // says at length why a guess beats Etc/UTC on a page; the fallback below is still the image's
    // own clock, because a configuration that names nothing is not asking for a guess.
    //
    // GeoIP is deliberately not implemented: the stock module's geoip block is `style: none` in
    // this medium's configuration and always has been, because asking the network where the
    // machine is, before the user has been told anything, is not this installer's manner.
    const QString region
        = Calamares::getString( configurationMap, QStringLiteral( "region" ) );
    const QString zone = Calamares::getString( configurationMap, QStringLiteral( "zone" ) );

    m_region = region.isEmpty() ? QStringLiteral( "Etc" ) : region;
    m_regionalZones->setRegion( m_region );
    m_zone = zone.isEmpty() ? QStringLiteral( "UTC" ) : zone;

    // ASKED BEFORE CLAMPING, WHICH IS THE ONLY MOMENT THE ANSWER EXISTS. clampZone() replaces an
    // unknown zone with the region's first, so a check made after it can only ever fail for a
    // region with no zones at all — it reported "the configured default X/Y … the page opened on
    // X/Y instead", naming the fallback twice and the configured value never. A default this
    // module cannot honour now says so, and says what it did instead: with a named place rather
    // than UTC in location.conf, the silent version of this is an installer that quietly picks
    // some other city in the same region and looks like it meant to.
    const bool defaultExists = m_zones->find( m_region, m_zone );
    const QString wanted = m_region + QLatin1Char( '/' ) + m_zone;

    clampZone();

    if ( !defaultExists )
    {
        cWarning() << "location: the configured default" << wanted
                   << "is not a zone this system's tzdata has; the page opened on"
                   << ( m_zone.isEmpty() ? QStringLiteral( "no zone" )
                                         : m_region + QLatin1Char( '/' ) + m_zone )
                   << "instead.";
    }

    // WHETHER THE CLOCK COMES OFF THE NETWORK, and the default is yes. It is a configuration key
    // rather than a literal because it is a decision about the product — see location.conf — and
    // because "what does this box start as?" should be answerable by grep rather than by reading
    // C++. Nothing APPLIES it here: setConfigurationMap runs while Calamares is still building
    // its pages, and a page that ran timedatectl before it was ever shown would be changing the
    // machine's clock during startup. LocationViewStep::onActivate() applies it.
    m_networkTime = Calamares::getBool( configurationMap, QStringLiteral( "networkTime" ), true );
    emit networkTimeChanged();

    emit locationChanged();
    emit tick();
}

QAbstractItemModel*
LocationConfig::regionsModel() const
{
    return m_regions;
}

QAbstractItemModel*
LocationConfig::zonesModel() const
{
    return m_regionalZones;
}

void
LocationConfig::setRegion( const QString& region )
{
    if ( region.isEmpty() || region == m_region )
    {
        return;
    }
    m_region = region;
    // THE PROXY FIRST, THEN THE ZONE. RegionalZonesModel filters on its `region` property, so
    // clamping before the filter has moved would clamp against the OLD region's zone list and
    // leave the page showing a zone the new region does not contain.
    m_regionalZones->setRegion( m_region );
    clampZone();
    emit locationChanged();
    emit tick();
}

void
LocationConfig::setZone( const QString& zone )
{
    if ( zone.isEmpty() || zone == m_zone )
    {
        return;
    }
    // REFUSED IF IT IS NOT IN THIS REGION, the same shape the disk page's setCurrentIndex has:
    // C++ is allowed to say no, and the QML puts the control back to whatever was accepted.
    if ( !m_zones->find( m_region, zone ) )
    {
        cWarning() << "location: refused" << zone << "- not a zone in" << m_region;
        return;
    }
    m_zone = zone;
    emit locationChanged();
    emit tick();
}

void
LocationConfig::clampZone()
{
    if ( m_zones->find( m_region, m_zone ) )
    {
        return;
    }
    // The region's first zone, taken through the proxy so that "first" means the same thing the
    // page's list means by it.
    if ( m_regionalZones->rowCount( QModelIndex() ) > 0 )
    {
        m_zone = m_regionalZones->data( m_regionalZones->index( 0, 0 ),
                                        Calamares::Locale::ZonesModel::KeyRole )
                     .toString();
    }
    else
    {
        m_zone.clear();
    }
}

QString
LocationConfig::zoneId() const
{
    if ( m_region.isEmpty() || m_zone.isEmpty() )
    {
        return {};
    }
    return m_region + QLatin1Char( '/' ) + m_zone;
}

QString
LocationConfig::offsetText() const
{
    const QByteArray id = ianaId( m_region, m_zone );
    if ( id.isEmpty() )
    {
        return {};
    }
    const QTimeZone tz( id );
    if ( !tz.isValid() )
    {
        return {};
    }
    const QDateTime now = QDateTime::currentDateTimeUtc();
    const int seconds = tz.offsetFromUtc( now );
    const QChar sign = seconds < 0 ? QChar( 0x2212 ) : QLatin1Char( '+' );  // U+2212 MINUS SIGN
    const int minutes = qAbs( seconds ) / 60;

    // "EDT · UTC−4" and "IST · UTC+5:30" — the minutes are printed only when there are any,
    // because "UTC+1:00" is two characters of noise on the twenty-odd zones that are whole hours.
    QString offset = QStringLiteral( "UTC%1%2" ).arg( sign ).arg( minutes / 60 );
    if ( minutes % 60 )
    {
        offset += QStringLiteral( ":%1" ).arg( minutes % 60, 2, 10, QLatin1Char( '0' ) );
    }

    const QString abbreviation = tz.abbreviation( now );
    return abbreviation.isEmpty() ? offset
                                  : abbreviation + QStringLiteral( " · " ) + offset;
}

QString
LocationConfig::clockTime() const
{
    const QByteArray id = ianaId( m_region, m_zone );
    const QDateTime now = id.isEmpty() ? QDateTime::currentDateTime()
                                       : QDateTime::currentDateTimeUtc().toTimeZone( QTimeZone( id ) );
    // QLocale, not a format string of our own: whether the clock reads 13:45 or 1:45 PM is a
    // property of the language the user chose on the page before this one, and Qt already knows.
    return QLocale().toString( now.time(), QLocale::ShortFormat );
}

QString
LocationConfig::clockDate() const
{
    const QByteArray id = ianaId( m_region, m_zone );
    const QDateTime now = id.isEmpty() ? QDateTime::currentDateTime()
                                       : QDateTime::currentDateTimeUtc().toTimeZone( QTimeZone( id ) );
    return QLocale().toString( now.date(), QLocale::LongFormat );
}

QString
LocationConfig::prettyStatus() const
{
    const QString id = zoneId();
    if ( id.isEmpty() )
    {
        return {};
    }
    const QString offset = offsetText();
    return offset.isEmpty() ? id : id + QStringLiteral( " · " ) + offset;
}

void
LocationConfig::publish() const
{
    auto* gs = Calamares::JobQueue::instance() ? Calamares::JobQueue::instance()->globalStorage()
                                              : nullptr;
    if ( !gs )
    {
        return;
    }
    // UPSTREAM'S KEY NAMES. `localesetup` is ours and reads these two, but so does anything else
    // in Calamares that wants to know where the machine is, and renaming a published contract
    // because the page that publishes it changed hands would be a change nobody can grep for.
    gs->insert( QStringLiteral( "locationRegion" ), m_region );
    gs->insert( QStringLiteral( "locationZone" ), m_zone );
    // AND THIS ONE IS OURS, which is why it is not spelled like the two above. Upstream's locale
    // module has no notion of network time, so there is no published contract to honour — and
    // naming it `useNTP` or `ntp` would have looked like one. `localesetup` is its only reader.
    gs->insert( QStringLiteral( "locationNetworkTime" ), m_networkTime );
}

void
LocationConfig::retranslate()
{
    emit retranslated();
    // The region and zone NAMES are upstream's translations, re-read from the models on a
    // language change; the models emit nothing, so the page is told to ask again.
    emit locationChanged();
    // ...and the clock's format is QLocale's, which has just changed with it.
    emit tick();
    // The status line is a COMPOSED string — "The clock is set from 0.pool.ntp.org." — so it is
    // not re-read by emitting a signal; it has to be built again in the new language.
    composeSyncStatus();
}

// ---- the clock on THIS machine (plan/29) ---------------------------------------------------
//
// Everything above this line describes the machine that will be installed. Everything below it
// changes the machine the installer is running on, which no other page here does — and it is
// allowed to because the clock is the one setting whose effect a user is asked to CHECK on this
// page. A page that shows you the time and cannot correct it is a page that shows you a problem.

bool
LocationConfig::timedatectl( const QStringList& args, QString* out )
{
    QProcess p;
    // MERGED, because the reason is on stderr. systemd's refusals are sentences —
    // "Failed to set time: Automatic time synchronization is enabled" — and they are better
    // shown to the user than replaced with an exit code.
    p.setProcessChannelMode( QProcess::MergedChannels );
    p.start( QStringLiteral( "timedatectl" ), args );
    if ( !p.waitForFinished( kTimedatectlTimeoutMs ) )
    {
        if ( out )
        {
            *out = p.errorString();
        }
        p.kill();
        p.waitForFinished( 1000 );
        return false;
    }
    if ( out )
    {
        *out = QString::fromUtf8( p.readAll() ).trimmed();
    }
    return p.exitStatus() == QProcess::NormalExit && p.exitCode() == 0;
}

void
LocationConfig::setNetworkTime( bool on )
{
    if ( on == m_networkTime )
    {
        return;
    }
    m_networkTime = on;
    emit networkTimeChanged();
    // PUBLISHED WITH THE BOX, not with the page. The view step publishes on leave and on
    // configure, which covers a user who walks forward; this covers one who ticks the box and
    // presses Back, and it costs two map writes.
    publish();
    applyNetworkTime();
}

void
LocationConfig::applyNetworkTime()
{
    QString out;
    if ( !timedatectl( { QStringLiteral( "set-ntp" ),
                         m_networkTime ? QStringLiteral( "true" ) : QStringLiteral( "false" ) },
                       &out ) )
    {
        // NOT FATAL, AND NOT SILENT. A medium whose timedated does not answer can still install —
        // the page's real output is the timezone and the answer `localesetup` carries — so this
        // reports what it could not do and leaves the rest of the page working.
        cWarning() << "location: timedatectl set-ntp" << m_networkTime << "failed:" << out;
        m_poll->stop();
        setSyncState( QStringLiteral( "unavailable" ) );
        return;
    }

    if ( m_networkTime )
    {
        beginSyncWatch();
    }
    else
    {
        m_poll->stop();
        setSyncState( QStringLiteral( "off" ) );
    }
}

void
LocationConfig::beginSyncWatch()
{
    m_pollsLeft = 20;
    setSyncState( QStringLiteral( "busy" ) );
    // ASKED ONCE BEFORE THE TIMER STARTS, because the common case on this medium is that
    // systemd-timesyncd has been running since boot and the answer is already yes. A page that
    // showed "Checking the time server…" for a second before admitting it had nothing to check
    // would be inventing work to look busy.
    pollSync();
    if ( m_syncState == QStringLiteral( "busy" ) )
    {
        m_poll->start();
    }
}

void
LocationConfig::pollSync()
{
    QString out;
    if ( !timedatectl( { QStringLiteral( "show" ), QStringLiteral( "-p" ),
                         QStringLiteral( "NTPSynchronized" ), QStringLiteral( "--value" ) },
                       &out ) )
    {
        m_poll->stop();
        setSyncState( QStringLiteral( "unavailable" ) );
        return;
    }

    if ( out.trimmed() == QLatin1String( "yes" ) )
    {
        m_poll->stop();
        // WHICH SERVER, if timesyncd will say. It is the difference between a page that claims
        // the network set the clock and a page that can be checked: a name here is something a
        // user or an administrator can look at and recognise — their DHCP server's, their domain
        // controller's, or the FallbackNTP list build.conf shipped.
        QString server;
        if ( !timedatectl( { QStringLiteral( "show-timesync" ), QStringLiteral( "-p" ),
                             QStringLiteral( "ServerName" ), QStringLiteral( "--value" ) },
                           &server ) )
        {
            server.clear();
        }
        server = server.trimmed();
        if ( server.isEmpty() )
        {
            // A server configured as a bare address has no name to report.
            QString address;
            if ( timedatectl( { QStringLiteral( "show-timesync" ), QStringLiteral( "-p" ),
                                QStringLiteral( "ServerAddress" ), QStringLiteral( "--value" ) },
                              &address ) )
            {
                server = address.trimmed();
            }
        }
        setSyncState( QStringLiteral( "ok" ), server );
        // The clock has almost certainly just moved. The page's own reading is on a one-second
        // timer anyway; this is so the correction appears at the moment it is announced.
        emit tick();
        return;
    }

    if ( --m_pollsLeft <= 0 )
    {
        m_poll->stop();
        setSyncState( QStringLiteral( "failed" ) );
    }
}

void
LocationConfig::setSyncState( const QString& state, const QString& server )
{
    if ( state == m_syncState && server == m_syncServer )
    {
        return;
    }
    m_syncState = state;
    m_syncServer = server;
    composeSyncStatus();
}

void
LocationConfig::composeSyncStatus()
{
    if ( m_syncState == QLatin1String( "busy" ) )
    {
        m_syncStatus = tr( "Checking the time server…" );
    }
    else if ( m_syncState == QLatin1String( "ok" ) )
    {
        m_syncStatus = m_syncServer.isEmpty()
            ? tr( "The clock is set from the network." )
            : tr( "The clock is set from %1." ).arg( m_syncServer );
    }
    else if ( m_syncState == QLatin1String( "failed" ) )
    {
        m_syncStatus = tr( "No time server answered. Check the network, or set the clock by hand." );
    }
    else if ( m_syncState == QLatin1String( "unavailable" ) )
    {
        m_syncStatus = tr( "This machine's clock service did not answer, so the time cannot be "
                           "set from here." );
    }
    else
    {
        m_syncStatus = tr( "The clock is set on this machine, not from the network." );
    }
    emit syncChanged();
}

QString
LocationConfig::editDate() const
{
    const QByteArray id = ianaId( m_region, m_zone );
    const QDateTime now = id.isEmpty()
        ? QDateTime::currentDateTime()
        : QDateTime::currentDateTimeUtc().toTimeZone( QTimeZone( id ) );
    return now.date().toString( QString::fromLatin1( kEditDateFormat ) );
}

QString
LocationConfig::editTime() const
{
    const QByteArray id = ianaId( m_region, m_zone );
    const QDateTime now = id.isEmpty()
        ? QDateTime::currentDateTime()
        : QDateTime::currentDateTimeUtc().toTimeZone( QTimeZone( id ) );
    return now.time().toString( QString::fromLatin1( kEditTimeFormat ) );
}

void
LocationConfig::clearSetTimeError()
{
    setSetTimeError( QString() );
}

void
LocationConfig::setSetTimeError( const QString& message )
{
    if ( message == m_setTimeError )
    {
        return;
    }
    m_setTimeError = message;
    emit setTimeErrorChanged();
}

bool
LocationConfig::applySystemTime( const QString& date, const QString& time )
{
    // systemd refuses this outright while NTP is on, and says so in a sentence about D-Bus. The
    // button that opens this dialog is disabled in that state, so reaching here means something
    // drove the page rather than a person — but the refusal should still be ours and in the
    // user's language rather than systemd's.
    if ( m_networkTime )
    {
        setSetTimeError( tr( "Turn off automatic time before setting the clock by hand." ) );
        return false;
    }

    const QDate d = QDate::fromString( date.trimmed(), QString::fromLatin1( kEditDateFormat ) );
    if ( !d.isValid() )
    {
        setSetTimeError( tr( "The date must be written year-month-day, as in %1." ).arg( editDate() ) );
        return false;
    }
    const QTime t = QTime::fromString( time.trimmed(), QString::fromLatin1( kEditTimeFormat ) );
    if ( !t.isValid() )
    {
        setSetTimeError(
            tr( "The time must be written on a 24-hour clock, as in %1." ).arg( editTime() ) );
        return false;
    }

    // READ IN THE CHOSEN ZONE, WRITTEN IN THE MACHINE'S. The page shows a clock in the zone the
    // user picked, so the time they type is a correction to THAT clock — but `timedatectl
    // set-time` reads its argument in the zone /etc/localtime names, which on this medium is UTC
    // and deliberately stays UTC (see modules/location.conf). Handing it the typed string
    // unconverted would set the machine hours wrong in exactly the way that looks like it worked.
    const QByteArray id = ianaId( m_region, m_zone );
    const QDateTime entered = id.isEmpty() ? QDateTime( d, t ) : QDateTime( d, t, QTimeZone( id ) );
    if ( !entered.isValid() )
    {
        // An hour that does not exist — the one a spring-forward skips.
        setSetTimeError( tr( "There is no such time in %1." ).arg( zoneId() ) );
        return false;
    }

    QString out;
    const QString argument
        = entered.toLocalTime().toString( QStringLiteral( "yyyy-MM-dd HH:mm:ss" ) );
    if ( !timedatectl( { QStringLiteral( "set-time" ), argument }, &out ) )
    {
        cWarning() << "location: timedatectl set-time" << argument << "failed:" << out;
        setSetTimeError( out.isEmpty() ? tr( "The clock could not be set." )
                                       : tr( "The clock could not be set: %1" ).arg( out ) );
        return false;
    }

    cDebug() << "location: system clock set to" << argument << "(local), from" << entered
             << "in" << zoneId();
    setSetTimeError( QString() );
    // systemd writes the RTC through on set-time, so the machine this medium installs onto starts
    // from this clock too. The page's reading is on a one-second timer; this is so the number the
    // user just typed appears the instant the dialog closes.
    emit tick();
    return true;
}

#include "moc_LocationConfig.cpp"
