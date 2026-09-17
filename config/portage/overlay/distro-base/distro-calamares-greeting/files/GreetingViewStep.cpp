/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "GreetingViewStep.h"

#include "GreetingConfig.h"
#include "Requirements.h"

#include "modulesystem/ModuleManager.h"
#include "modulesystem/RequirementsModel.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWidget>

CALAMARES_PLUGIN_FACTORY_DEFINITION( GreetingViewStepFactory, registerPlugin< GreetingViewStep >(); )

GreetingViewStep::GreetingViewStep( QObject* parent )
    : Calamares::ViewStep( parent )
    , m_requirements( new Requirements( this ) )
    , m_config( new GreetingConfig( this ) )
{
    // NO QQuickStyle::setStyle() HERE, and its absence is deliberate rather than forgotten: the
    // call belongs to whichever module loads FIRST — the language module — because Qt ignores it
    // once anything has imported Qt Quick Controls. That was true when this page drew no QML at
    // all and is no less true now that it does; a second call here would look like it was doing
    // something and would be dead code.
    if ( QQuickStyle::name() != QStringLiteral( "org.kde.desktop" ) )
    {
        cWarning() << "greeting: Qt Quick Controls style is" << QQuickStyle::name()
                   << "- this page expects org.kde.desktop for its icons, colours and metrics.";
    }

    // QML BINDINGS DO NOT RETRANSLATE BY THEMSELVES: a QTranslator swap posts
    // QEvent::LanguageChange, which re-evals QObject::tr() consumers, while a binding onto one is
    // only re-evaluated when the engine is told to. Same line, same reason, as every QML module
    // in this installer.
    CALAMARES_RETRANSLATE( if ( m_widget && m_widget->engine() ) { m_widget->engine()->retranslate(); } );

    auto* manager = Calamares::ModuleManager::instance();
    auto* model = manager ? manager->requirementsModel() : nullptr;
    if ( model )
    {
        // Next is gated on the mandatory checks, so the button has to be re-asked every time that
        // verdict moves. ViewManager only re-reads the navigation state after its own back()/next()
        // — a change that originates in a five-second re-check reaches it through this signal or
        // not at all, and "attach a bigger disk and the page clears itself" is the behaviour that
        // depends on it.
        connect( model, &Calamares::RequirementsModel::satisfiedMandatoryChanged, this, [ this ]( bool ok )
                 { emit nextStatusChanged( ok ); } );
    }
}

GreetingViewStep::~GreetingViewStep()
{
    if ( m_widget && m_widget->parent() == nullptr )
    {
        m_widget->deleteLater();
    }
}

QString
GreetingViewStep::prettyName() const
{
    // "Welcome" in the sidebar, `greeting` on disk — see the header for why those two cannot be
    // the same word.
    return tr( "Welcome" );
}

QWidget*
GreetingViewStep::widget()
{
    if ( !m_widget )
    {
        m_widget = new QQuickWidget();
        m_widget->setResizeMode( QQuickWidget::SizeRootObjectToView );
        m_widget->rootContext()->setContextProperty( QStringLiteral( "greeting" ), m_config );
        // qrc:, not a file path — the QML is a resource compiled into this plugin, so there is no
        // second install path and no search order to get wrong (plan/21 §2).
        m_widget->setSource( QUrl( QStringLiteral( "qrc:/greeting/qml/Greeting.qml" ) ) );
    }
    return m_widget;
}

bool
GreetingViewStep::isNextEnabled() const
{
    // THE MANDATORY LIST ONLY. greeting.conf requires storage, ram and root and checks three more;
    // an install with no network is a supported path on this medium and a laptop on battery is
    // nobody's business, so those two are reported and do not block.
    //
    // False before the first round finishes, which is correct: until the checks have run, nothing
    // is known, and a Next that was enabled for the second the scan takes would let a user past a
    // machine that cannot install.
    // NOT `const auto* manager`, which is the obvious way to write this and does not compile:
    // ModuleManager::requirementsModel() is a non-const accessor (ModuleManager.h:106), so a
    // const pointer to the singleton cannot call it. The MODEL is const here, which is the half
    // that matters — this function reads a verdict and changes nothing.
    auto* manager = Calamares::ModuleManager::instance();
    const auto* model = manager ? manager->requirementsModel() : nullptr;
    return model ? model->satisfiedMandatory() : false;
}

bool
GreetingViewStep::isBackEnabled() const
{
    // TRUE, and this is the one that matters: stock WelcomeViewStep returns false because it is
    // the first step and has nowhere to go. This page has the language list behind it, and Back is
    // how somebody who picked the wrong language gets to it.
    return true;
}

bool
GreetingViewStep::isAtBeginning() const
{
    return true;
}

bool
GreetingViewStep::isAtEnd() const
{
    return true;
}

Calamares::JobList
GreetingViewStep::jobs() const
{
    return Calamares::JobList();
}

Calamares::RequirementsList
GreetingViewStep::checkRequirements()
{
    return m_requirements->checkRequirements();
}

void
GreetingViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_requirements->setConfigurationMap( configurationMap );
}

#include "moc_GreetingViewStep.cpp"
