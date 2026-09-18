/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "KeymapViewStep.h"

#include "KeymapConfig.h"

#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWidget>

CALAMARES_PLUGIN_FACTORY_DEFINITION( KeymapViewStepFactory, registerPlugin< KeymapViewStep >(); )

KeymapViewStep::KeymapViewStep( QObject* parent )
    : Calamares::ViewStep( parent )
    , m_config( new KeymapConfig( this ) )
{
    // NO QQuickStyle::setStyle() HERE — it belongs to whichever module loads FIRST, the language
    // page, and is silently ignored everywhere else.
    if ( QQuickStyle::name() != QStringLiteral( "org.kde.desktop" ) )
    {
        cWarning() << "keymap: Qt Quick Controls style is" << QQuickStyle::name()
                   << "- this page expects org.kde.desktop for its icons, colours and metrics.";
    }

    CALAMARES_RETRANSLATE( if ( m_widget && m_widget->engine() ) { m_widget->engine()->retranslate(); } );
}

KeymapViewStep::~KeymapViewStep()
{
    if ( m_widget && m_widget->parent() == nullptr )
    {
        m_widget->deleteLater();
    }
}

QString
KeymapViewStep::prettyName() const
{
    return tr( "Keyboard" );
}

QString
KeymapViewStep::prettyStatus() const
{
    return m_config->prettyStatus();
}

QWidget*
KeymapViewStep::widget()
{
    if ( !m_widget )
    {
        m_widget = new QQuickWidget();
        m_widget->setResizeMode( QQuickWidget::SizeRootObjectToView );
        m_widget->rootContext()->setContextProperty( QStringLiteral( "keymap" ), m_config );
        // qrc:, not a file path — the QML is a resource compiled into this plugin (plan/21 §2).
        m_widget->setSource( QUrl( QStringLiteral( "qrc:/keymap/qml/Keymap.qml" ) ) );
    }
    return m_widget;
}

bool
KeymapViewStep::isNextEnabled() const
{
    // TRUE, INCLUDING WHEN THE REGISTRY COULD NOT BE READ. The page opens on the medium's
    // configured default — `us`, which is what the image ships as KEYMAP — so there is no state
    // in which nothing is chosen; and a medium with no xkeyboard-config offers no layouts at all,
    // which the page says out loud and which must not be a dead end: the installed system keeping
    // the layout the medium booted with is a defensible outcome, and refusing to continue would
    // make a missing package into an unfinishable install.
    return true;
}

bool
KeymapViewStep::isBackEnabled() const
{
    return true;
}

bool
KeymapViewStep::isAtBeginning() const
{
    return true;
}

bool
KeymapViewStep::isAtEnd() const
{
    return true;
}

Calamares::JobList
KeymapViewStep::jobs() const
{
    return Calamares::JobList();
}

void
KeymapViewStep::onLeave()
{
    m_config->publish();
}

void
KeymapViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_config->setConfigurationMap( configurationMap );
    // PUBLISHED ON CONFIGURATION TOO, not only on leave — the location page's reasoning exactly:
    // `keyboardsetup` runs in the exec phase and reads these keys, and the job should be given
    // the medium's own default rather than left to infer one from a missing key.
    m_config->publish();
}

#include "moc_KeymapViewStep.cpp"
