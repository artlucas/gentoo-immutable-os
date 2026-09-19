/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "LocationViewStep.h"

#include "LocationConfig.h"

#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWidget>

CALAMARES_PLUGIN_FACTORY_DEFINITION( LocationViewStepFactory, registerPlugin< LocationViewStep >(); )

LocationViewStep::LocationViewStep( QObject* parent )
    : Calamares::ViewStep( parent )
    , m_config( new LocationConfig( this ) )
{
    // NO QQuickStyle::setStyle() HERE — it belongs to whichever module loads FIRST, the language
    // page, and is silently ignored everywhere else.
    if ( QQuickStyle::name() != QStringLiteral( "org.kde.desktop" ) )
    {
        cWarning() << "location: Qt Quick Controls style is" << QQuickStyle::name()
                   << "- this page expects org.kde.desktop for its icons, colours and metrics.";
    }

    CALAMARES_RETRANSLATE( if ( m_widget && m_widget->engine() ) { m_widget->engine()->retranslate(); } );
}

LocationViewStep::~LocationViewStep()
{
    if ( m_widget && m_widget->parent() == nullptr )
    {
        m_widget->deleteLater();
    }
}

QString
LocationViewStep::prettyName() const
{
    return tr( "Location" );
}

QString
LocationViewStep::prettyStatus() const
{
    return m_config->prettyStatus();
}

QWidget*
LocationViewStep::widget()
{
    if ( !m_widget )
    {
        m_widget = new QQuickWidget();
        m_widget->setResizeMode( QQuickWidget::SizeRootObjectToView );
        m_widget->rootContext()->setContextProperty( QStringLiteral( "location" ), m_config );
        // qrc:, not a file path — the QML is a resource compiled into this plugin (plan/21 §2).
        m_widget->setSource( QUrl( QStringLiteral( "qrc:/location/qml/Location.qml" ) ) );
    }
    return m_widget;
}

bool
LocationViewStep::isNextEnabled() const
{
    // TRUE. The page opens on the medium's configured default — Etc/UTC, which is what the image
    // ships — so there is no state in which nothing is chosen. A gate here would be a gate that
    // can never close.
    return true;
}

bool
LocationViewStep::isBackEnabled() const
{
    return true;
}

bool
LocationViewStep::isAtBeginning() const
{
    return true;
}

bool
LocationViewStep::isAtEnd() const
{
    return true;
}

Calamares::JobList
LocationViewStep::jobs() const
{
    return Calamares::JobList();
}

void
LocationViewStep::onActivate()
{
    // THE PAGE'S FIRST ACT IS THE ONE IT IS PROMISING. The network-time box is checked when the
    // page opens (modules/location.conf), so leaving the machine alone until somebody touched it
    // would be a checked box that had done nothing — and on a medium where systemd-timesyncd has
    // been running since boot, the box would be telling the truth by accident rather than saying
    // anything about what this page did.
    //
    // HERE RATHER THAN IN setConfigurationMap(), which runs while Calamares is still building its
    // pages: a page that ran timedatectl during startup would change the machine's clock before
    // anything had been shown to anyone.
    //
    // ON EVERY ENTRY, not only the first. A user who comes back to this page has just been
    // somewhere else for a while, and re-asking is how "the clock is set from 0.pool.ntp.org"
    // stays a statement about now rather than a statement about a minute ago.
    m_config->applyNetworkTime();
}

void
LocationViewStep::onLeave()
{
    m_config->publish();
}

void
LocationViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_config->setConfigurationMap( configurationMap );
    // PUBLISHED ON CONFIGURATION TOO, not only on leave. `localesetup` runs in the exec phase and
    // reads these keys; a user who never opens this page — there is no such path today, but the
    // sequence is a configuration file — would otherwise leave the job with nothing to read and
    // the target with whatever /etc/localtime the image shipped. That is the right answer, and it
    // should be the answer the job gives rather than the answer a missing key falls into.
    m_config->publish();
}

#include "moc_LocationViewStep.cpp"
