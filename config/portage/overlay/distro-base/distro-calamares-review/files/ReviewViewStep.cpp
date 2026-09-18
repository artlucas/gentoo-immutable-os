/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "ReviewViewStep.h"

#include "ReviewConfig.h"

#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWidget>

CALAMARES_PLUGIN_FACTORY_DEFINITION( ReviewViewStepFactory, registerPlugin< ReviewViewStep >(); )

ReviewViewStep::ReviewViewStep( QObject* parent )
    : Calamares::ViewStep( parent )
    , m_config( new ReviewConfig( this ) )
{
    // NO QQuickStyle::setStyle() HERE. The call is ignored once anything has imported
    // QtQuick.Controls, so it belongs to whichever module loads FIRST — the language page, which
    // says so at length. A second call here would look like it was doing something.
    if ( QQuickStyle::name() != QStringLiteral( "org.kde.desktop" ) )
    {
        cWarning() << "review: Qt Quick Controls style is" << QQuickStyle::name()
                   << "- this page expects org.kde.desktop for its icons, colours and metrics.";
    }

    CALAMARES_RETRANSLATE( if ( m_widget && m_widget->engine() ) { m_widget->engine()->retranslate(); } );
}

ReviewViewStep::~ReviewViewStep()
{
    if ( m_widget && m_widget->parent() == nullptr )
    {
        m_widget->deleteLater();
    }
}

QString
ReviewViewStep::prettyName() const
{
    // "Summary" in the sidebar, `review` on disk — see the header for why those two cannot be the
    // same word.
    return tr( "Summary" );
}

QWidget*
ReviewViewStep::widget()
{
    if ( !m_widget )
    {
        m_widget = new QQuickWidget();
        m_widget->setResizeMode( QQuickWidget::SizeRootObjectToView );
        m_widget->rootContext()->setContextProperty( QStringLiteral( "review" ), m_config );
        // qrc:, not a file path — the QML is a resource compiled into this plugin, so there is no
        // second install path and no search order to get wrong (plan/21 §2).
        m_widget->setSource( QUrl( QStringLiteral( "qrc:/review/qml/Review.qml" ) ) );
    }
    return m_widget;
}

void
ReviewViewStep::onActivate()
{
    m_config->collect( this );
}

bool
ReviewViewStep::isNextEnabled() const
{
    // TRUE. Everything this page reports was gated on the page that asked it — the disk page will
    // not leave without a confirmed erase, the accounts page will not leave without an account.
    // A second gate here would be a second opinion about answers that are already settled.
    return true;
}

bool
ReviewViewStep::isBackEnabled() const
{
    return true;
}

bool
ReviewViewStep::isAtBeginning() const
{
    return true;
}

bool
ReviewViewStep::isAtEnd() const
{
    return true;
}

Calamares::JobList
ReviewViewStep::jobs() const
{
    return Calamares::JobList();
}

void
ReviewViewStep::setConfigurationMap( const QVariantMap& )
{
    // Nothing to configure, and the .conf beside this module exists only so that
    // calamares_add_plugin does not stamp `noconfig: true` — see the CMakeLists.
}

#include "moc_ReviewViewStep.cpp"
