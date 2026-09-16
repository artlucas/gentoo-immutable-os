/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "AppsViewStep.h"

#include "AppsConfig.h"

#include "JobQueue.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWidget>
#include <QUrl>

CALAMARES_PLUGIN_FACTORY_DEFINITION( AppsViewStepFactory, registerPlugin< AppsViewStep >(); )

AppsViewStep::AppsViewStep( QObject* parent )
    : Calamares::ViewStep( parent )
    , m_config( new AppsConfig( this ) )
{
    // NO QQuickStyle::setStyle() HERE, and its absence is asserted by tests/test-installer.sh.
    // The call is silently ignored once anything has imported QtQuick.Controls, so it belongs to
    // whichever module ModuleManager loads first — the language page, which is the first entry in
    // settings.conf's sequence and says so at length. A second call here would look like it was
    // doing something and would be dead code.
    if ( QQuickStyle::name() != QStringLiteral( "org.kde.desktop" ) )
    {
        cWarning() << "apps: Qt Quick Controls style is" << QQuickStyle::name()
                   << "- this page expects org.kde.desktop for its icons, colours and metrics.";
    }

    // QML BINDINGS DO NOT RETRANSLATE BY THEMSELVES: a QTranslator swap posts
    // QEvent::LanguageChange, which re-evals QObject::tr() consumers, while a qsTr() inside a QML
    // binding is only re-evaluated when the engine is told to. Same line, same reason, as every
    // QML module in this installer.
    CALAMARES_RETRANSLATE( if ( m_widget && m_widget->engine() ) { m_widget->engine()->retranslate(); } );
}

AppsViewStep::~AppsViewStep()
{
    if ( m_widget && m_widget->parent() == nullptr )
    {
        m_widget->deleteLater();
    }
}

QString
AppsViewStep::prettyName() const
{
    // "Applications", because the sidebar names what the user chooses on each page — and on this
    // one the noun is the whole subject: which applications, whether any, and (in the job's half)
    // whether the ones already chosen by the image get updated.
    return tr( "Applications" );
}

QString
AppsViewStep::prettyStatus() const
{
    return m_config->prettyStatus();
}

QWidget*
AppsViewStep::widget()
{
    if ( !m_widget )
    {
        m_widget = new QQuickWidget();
        m_widget->setResizeMode( QQuickWidget::SizeRootObjectToView );
        m_widget->rootContext()->setContextProperty( QStringLiteral( "apps" ), m_config );
        // qrc:, not a file path — the QML is a resource compiled into this plugin, so there is no
        // second install path and no search order to get wrong (plan/21 §2).
        m_widget->setSource( QUrl( QStringLiteral( "qrc:/apps/qml/Apps.qml" ) ) );
    }
    return m_widget;
}

bool
AppsViewStep::isNextEnabled() const
{
    // TRUE ALWAYS, and offline is the case that proves it has to be: when there is no connection
    // the page pre-answers "nothing extra", and that IS an answer — the payload's applications are
    // already on the disk and the install is complete without this page doing anything. Gating
    // Next on connectivity would turn a supported, first-class offline install (greeting.conf's
    // `required:` list deliberately omits internet) into one that cannot proceed past a page
    // whose whole purpose is optional.
    return true;
}

bool
AppsViewStep::isBackEnabled() const
{
    return true;
}

bool
AppsViewStep::isAtBeginning() const
{
    // ONE SCREEN. Both are constants, and that is what makes the window's Back and Next leave
    // this module rather than move inside it. The accounts page is the one module here that
    // answers these with state.
    return true;
}

bool
AppsViewStep::isAtEnd() const
{
    return true;
}

Calamares::JobList
AppsViewStep::jobs() const
{
    return Calamares::JobList();
}

void
AppsViewStep::onActivate()
{
    // EVERY TIME IN, not once at startup. The greeting page checked the internet when Calamares
    // gathered requirements, before the first page was drawn; this page is four steps later and
    // is re-entered from the summary's Back. Networks come up in that window — a Wi-Fi pick on
    // the locale page, a cable found while reading the disk page — and "the page offered nothing
    // because the answer was taken five minutes ago" is a worse failure than asking twice.
    m_config->recheckInternet();
}

void
AppsViewStep::onLeave()
{
    // onLeave() fires on the way BACK as well as forward and Calamares gives a ViewStep no way to
    // tell the two apart. Publishing in both directions is harmless here: the keys describe what
    // is currently chosen, and stepping back to the accounts page and forward again re-publishes
    // the same two values. The offline case publishes its forced answer the same way — `appsetup`
    // re-checks the network itself and skips everything offline, so a page answer of "typical"
    // published seconds before the cable came out still installs nothing and fails nothing.
    m_config->publish( Calamares::JobQueue::instance()->globalStorage() );
}

void
AppsViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_config->setConfigurationMap( configurationMap );
}

#include "moc_AppsViewStep.cpp"
