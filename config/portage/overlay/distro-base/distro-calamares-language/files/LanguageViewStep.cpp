/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "LanguageViewStep.h"

#include "LanguageConfig.h"

#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWidget>
#include <QUrl>

CALAMARES_PLUGIN_FACTORY_DEFINITION( LanguageViewStepFactory, registerPlugin< LanguageViewStep >(); )

LanguageViewStep::LanguageViewStep( QObject* parent )
    : Calamares::ViewStep( parent )
    , m_config( new LanguageConfig( this ) )
{
    // THE STYLE, SET IN THE FIRST MODULE IN THE SEQUENCE, WHICH IS WHERE IT BELONGS.
    //
    // Kirigami picks its platform integration plugin from the Qt Quick Controls style's name, and
    // that plugin is what initialises the icon theme — so the wrong style costs Breeze's colours,
    // Breeze's metrics and every icon at once, on every QML page in this installer. The call is
    // silently ignored once anything has imported QtQuick.Controls, so it has to happen in
    // whichever module loads first, and ModuleManager::loadModules() walks settings.conf's
    // sequence in order. That is this one.
    //
    // The guard is the ENVIRONMENT VARIABLE and not QQuickStyle::name(), which is the mistake the
    // accounts page paid a VM boot to find: name() does not report "nobody has chosen", it
    // resolves a style and answers "Fusion". pkexec strips the variable out of the session that
    // set it, which is why the installer has to set its own, and why somebody debugging with
    // QT_QUICK_CONTROLS_STYLE=Basic still gets Basic.
    if ( qEnvironmentVariableIsEmpty( "QT_QUICK_CONTROLS_STYLE" ) )
    {
        QQuickStyle::setStyle( QStringLiteral( "org.kde.desktop" ) );
    }
    if ( QQuickStyle::name() != QStringLiteral( "org.kde.desktop" ) )
    {
        cWarning() << "language: Qt Quick Controls style is" << QQuickStyle::name()
                   << "- every QML page in this installer expects org.kde.desktop for its icons, "
                      "colours and metrics.";
    }

    // QML BINDINGS DO NOT RETRANSLATE BY THEMSELVES. A QTranslator swap posts
    // QEvent::LanguageChange, which re-runs QObject::tr() consumers; a qsTr() inside a QML binding
    // is only re-evaluated when the engine is told to, and nothing tells it. This is the same line
    // Slideshow.cpp:57 carries for the same reason — and its absence is why the accounts page's
    // qsTr() strings stayed in the language the installer started in.
    CALAMARES_RETRANSLATE( if ( m_widget && m_widget->engine() ) { m_widget->engine()->retranslate(); } );
}

LanguageViewStep::~LanguageViewStep()
{
    if ( m_widget && m_widget->parent() == nullptr )
    {
        m_widget->deleteLater();
    }
}

QString
LanguageViewStep::prettyName() const
{
    // "Language", not "Welcome". Every other entry in this installer's sidebar names a thing the
    // user sets — Location, Keyboard, Partitions, Accounts — and "Welcome" was the only one that
    // named a mood. It is also the reason the module is not called `welcome`: a compiled plugin of
    // that name would install over app-admin/calamares' own and be blocked by Portage.
    return tr( "Language" );
}

QString
LanguageViewStep::prettyStatus() const
{
    return m_config->prettyStatus();
}

QWidget*
LanguageViewStep::widget()
{
    if ( !m_widget )
    {
        m_widget = new QQuickWidget();
        m_widget->setResizeMode( QQuickWidget::SizeRootObjectToView );
        m_widget->rootContext()->setContextProperty( QStringLiteral( "language" ), m_config );
        // qrc:, not a file path — the QML is a resource compiled into this plugin, so there is no
        // second install path and no search order to get wrong (plan/21 §2, and it holds here).
        m_widget->setSource( QUrl( QStringLiteral( "qrc:/language/qml/Language.qml" ) ) );
    }
    return m_widget;
}

bool
LanguageViewStep::isNextEnabled() const
{
    // ALWAYS, and it is not an oversight that the requirement checks are not consulted here. A
    // language is always selected — setConfigurationMap() picks one before the page is ever drawn
    // — and the checks belong to the NEXT step now (plan/23 §3), which is where Next is gated on
    // them. Making the installer's very first Next wait on an asynchronous disk scan would be a
    // page that looks broken for the second it takes.
    return true;
}

bool
LanguageViewStep::isBackEnabled() const
{
    // TRUE, and stock WelcomeViewStep returns false. ViewManager already special-cases the first
    // step:
    //
    //   // ViewManager.cpp:487
    //   UPDATE_BUTTON_PROPERTY( backEnabled,
    //                           ( m_currentStep == 0 && m_steps.first()->isAtBeginning() )
    //                               ? false : m_steps.at( m_currentStep )->isBackEnabled() );
    //
    // So the window disables Back on this page by itself, because this step IS the first one and
    // is always at its beginning. Returning false here as well would add nothing today and would
    // strand the user the first time anything is inserted ahead of this module.
    return true;
}

bool
LanguageViewStep::isAtBeginning() const
{
    // One screen, so both of these are constants — and their being constants is what makes the
    // window's Back and Next leave this module rather than move inside it (ViewManager::back()
    // calls step->back() whenever isAtBeginning() is false, and next() likewise on isAtEnd()).
    // Until plan/23 they reported which of two screens was showing.
    return true;
}

bool
LanguageViewStep::isAtEnd() const
{
    return true;
}

Calamares::JobList
LanguageViewStep::jobs() const
{
    return Calamares::JobList();
}

void
LanguageViewStep::onLeave()
{
    m_config->publish();
}

void
LanguageViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_config->setConfigurationMap( configurationMap );
}

#include "moc_LanguageViewStep.cpp"
