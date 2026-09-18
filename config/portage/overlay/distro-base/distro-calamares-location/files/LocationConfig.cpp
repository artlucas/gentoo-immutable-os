/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "LocationConfig.h"

#include "GlobalStorage.h"
#include "JobQueue.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"
#include "utils/Variant.h"

#include <QDateTime>
#include <QLocale>
#include <QTimeZone>
#include <QTimer>

namespace
{
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
}

void
LocationConfig::setConfigurationMap( const QVariantMap& configurationMap )
{
    // The default pin, before the user chooses. The medium's own configuration says Etc/UTC —
    // what the image ships — so this is "unchanged" rather than a guess about where the machine
    // is. GeoIP is deliberately not implemented: the stock module's geoip block is `style: none`
    // in this medium's configuration and always has been, because asking the network where the
    // machine is, before the user has been told anything, is not this installer's manner.
    const QString region
        = Calamares::getString( configurationMap, QStringLiteral( "region" ) );
    const QString zone = Calamares::getString( configurationMap, QStringLiteral( "zone" ) );

    m_region = region.isEmpty() ? QStringLiteral( "Etc" ) : region;
    m_regionalZones->setRegion( m_region );
    m_zone = zone.isEmpty() ? QStringLiteral( "UTC" ) : zone;
    clampZone();

    if ( !m_zones->find( m_region, m_zone ) )
    {
        cWarning() << "location: the configured default" << m_region << "/" << m_zone
                   << "is not a zone this system's tzdata has; the page opened on"
                   << m_region << "/" << m_zone << "instead.";
    }

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
}

#include "moc_LocationConfig.cpp"
