/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "DoneViewStep.h"

#include "DoneConfig.h"

#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QApplication>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWidget>

CALAMARES_PLUGIN_FACTORY_DEFINITION( DoneViewStepFactory, registerPlugin< DoneViewStep >(); )

DoneViewStep::DoneViewStep( QObject* parent )
    : Calamares::ViewStep( parent )
    , m_config( new DoneConfig( this ) )
{
    // NO QQuickStyle::setStyle() HERE — it belongs to whichever module loads FIRST, which is the
    // language page. A second call is silently ignored and would read as if it did something.
    if ( QQuickStyle::name() != QStringLiteral( "org.kde.desktop" ) )
    {
        cWarning() << "done: Qt Quick Controls style is" << QQuickStyle::name()
                   << "- this page expects org.kde.desktop for its icons, colours and metrics.";
    }

    CALAMARES_RETRANSLATE( if ( m_widget && m_widget->engine() ) { m_widget->engine()->retranslate(); } );
}

DoneViewStep::~DoneViewStep()
{
    if ( m_widget && m_widget->parent() == nullptr )
    {
        m_widget->deleteLater();
    }
}

QString
DoneViewStep::prettyName() const
{
    // "Finish" in the sidebar, `done` on disk — see the header for why those cannot be the same
    // word.
    return tr( "Finish" );
}

QWidget*
DoneViewStep::widget()
{
    if ( !m_widget )
    {
        m_widget = new QQuickWidget();
        m_widget->setResizeMode( QQuickWidget::SizeRootObjectToView );
        m_widget->rootContext()->setContextProperty( QStringLiteral( "done" ), m_config );
        // qrc:, not a file path — the QML is a resource compiled into this plugin (plan/21 §2).
        m_widget->setSource( QUrl( QStringLiteral( "qrc:/done/qml/Done.qml" ) ) );
    }
    return m_widget;
}

void
DoneViewStep::onActivate()
{
    m_config->collect();

    if ( !m_quitConnected )
    {
        // UPSTREAM'S ARRANGEMENT, and the reason is the ordering rather than the style: the
        // restart command has to run after Calamares has released whatever it is holding — the
        // target's mounts above all — and aboutToQuit is the last point at which this object is
        // still alive and the window is already going. Connected ONCE, because walking back into
        // this page would otherwise arm a second copy and reboot the machine twice.
        connect( qApp, &QApplication::aboutToQuit, m_config, &DoneConfig::doRestart );
        m_quitConnected = true;
    }
}

bool
DoneViewStep::isNextEnabled() const
{
    // FALSE, as upstream's does. There is nothing after this page: the navigation bar's Next is
    // dark and the Quit button beside it is what leaves — which, with the box ticked, is what
    // restarts the machine.
    return false;
}

bool
DoneViewStep::isBackEnabled() const
{
    // FALSE, and this one is not upstream's taste but this installer's situation: every page
    // behind this one asks a question about an install that has already been written to a disk.
    // Back from here would offer to change an answer that can no longer be changed.
    return false;
}

bool
DoneViewStep::isAtBeginning() const
{
    return true;
}

bool
DoneViewStep::isAtEnd() const
{
    return true;
}

Calamares::JobList
DoneViewStep::jobs() const
{
    return Calamares::JobList();
}

void
DoneViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_config->setConfigurationMap( configurationMap );
}

#include "moc_DoneViewStep.cpp"
