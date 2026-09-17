/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "LanguageViewStep.h"

#include "LanguageConfig.h"

#include "ViewManager.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QApplication>
#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWidget>
#include <QUrl>
#include <QWidget>

CALAMARES_PLUGIN_FACTORY_DEFINITION( LanguageViewStepFactory, registerPlugin< LanguageViewStep >(); )

/** @brief Re-say the words in the main window's own QML panels.
 *
 * THE SIDEBAR IS NOBODY'S MODULE, AND SO NOBODY RETRANSLATES IT. branding.desc asks for
 * `sidebar: qml` (plan/26 §5), which makes the panel down the left a QQuickWidget that
 * CalamaresWindow built from calamares-sidebar.qml — and CalamaresWindow.cpp wires no
 * retranslation to it whatsoever. Two different caches go stale there the moment the language
 * changes, and this function clears both, because this is the module that changes the language.
 *
 * The step names first. They are bound `text: display` on the ViewManager model, whose data()
 * asks each step for its prettyName() afresh every time it is called — which is why the WIDGET
 * flavour needs no signal at all (ProgressTreeView repaints and the words come back translated)
 * and why ViewManager emits dataChanged() from nowhere in upstream. A QML delegate binding does
 * not repaint-and-re-read: it re-reads on dataChanged() and on nothing else. So dataChanged() is
 * emitted here, for every row and every role, on a model this module does not own — the one
 * liberty in this file, taken because the alternative is a sidebar that names the steps in the
 * language the installer started in.
 *
 * Then "About" and "Debug", which are qsTranslate() bindings inside that QML (plan/27 §3). A
 * translation binding is re-evaluated when its engine is told to retranslate and at no other
 * time — exactly the fact the m_widget line in the constructor exists for, one engine further
 * out.
 *
 * The panels are found by the file they were built from, because the window gives them no
 * objectName. Our own pages' QQuickWidgets are children of the same window and are deliberately
 * not matched: they load from qrc: and each re-says for itself.
 */
static void
retranslateWindowPanels()
{
    const auto isPanel = []( const QQuickWidget* w )
    {
        const QString file = w->source().fileName();
        return file == QLatin1String( "calamares-sidebar.qml" )
            || file == QLatin1String( "calamares-navigation.qml" );
    };

    const auto windows = QApplication::topLevelWidgets();
    for ( const QWidget* top : windows )
    {
        const auto panels = top->findChildren< QQuickWidget* >();
        for ( QQuickWidget* panel : panels )
        {
            if ( isPanel( panel ) && panel->engine() )
            {
                panel->engine()->retranslate();
            }
        }
    }

    auto* views = Calamares::ViewManager::instance();
    if ( views && views->rowCount() > 0 )
    {
        emit views->dataChanged( views->index( 0, 0 ), views->index( views->rowCount() - 1, 0 ) );
    }
}

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
    //
    // The second call is the window's sidebar, which has the same problem and no module to fix it
    // — see retranslateWindowPanels() above. It runs from here because this page is where the
    // language changes, and it is harmless before the window exists: at attach time (the macro
    // calls the body once immediately) there are no top-level widgets and no view steps yet.
    CALAMARES_RETRANSLATE( if ( m_widget && m_widget->engine() ) { m_widget->engine()->retranslate(); }
                           retranslateWindowPanels(); );
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
