/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "AccountsViewStep.h"

#include "AccountsConfig.h"

#include "GlobalStorage.h"
#include "JobQueue.h"
#include "ViewManager.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QUrl>
#include <QQuickWidget>

CALAMARES_PLUGIN_FACTORY_DEFINITION( AccountsViewStepFactory, registerPlugin< AccountsViewStep >(); )

AccountsViewStep::AccountsViewStep( QObject* parent )
    : Calamares::ViewStep( parent )
    , m_config( new AccountsConfig( this ) )
{
    // THE STYLE, AND THE GUARD THAT NEVER FIRED.
    //
    // Without org.kde.desktop the page looks like nothing else on the medium: no Breeze colours,
    // no Breeze metrics, and — because Kirigami picks its platform integration plugin from the
    // style's name, and that plugin is what initialises the icon theme — no icons at all.
    //
    // This once read `if ( QQuickStyle::name().isEmpty() )`, which is wrong, and wrong in the
    // way that costs a VM boot to find: name() does not report "nobody has chosen", it RESOLVES
    // a style and reports the answer, and on Linux since Qt 6.7 the answer with nothing
    // configured is "Fusion". Measured in this medium's own Qt, under the environment
    // `pkexec calamares` actually gets: name() == "Fusion" before the call, so the guard never
    // fired, and the page had never once rendered in the style it was written for — three
    // symptoms in one screenshot (Fusion draws the radio indicator on the RIGHT, paints every
    // delegate with palette.base, and leaves Kirigami on its no-icon fallback theme).
    //
    // The environment variable is the guard instead, because it is the only thing here that
    // expresses a CHOICE. A resolved default is not a choice, and pkexec strips the variable out
    // of the session that set it (Plasma exports org.kde.desktop), which is why the installer
    // has to set its own. Somebody debugging with QT_QUICK_CONTROLS_STYLE=Basic still gets Basic.
    if ( qEnvironmentVariableIsEmpty( "QT_QUICK_CONTROLS_STYLE" ) )
    {
        QQuickStyle::setStyle( QStringLiteral( "org.kde.desktop" ) );
    }
    // setStyle() is silently ignored once anything has imported QtQuick.Controls — a warning on
    // stderr and nothing else. If another module ever loads QML before this constructor runs,
    // that is the line in the log that says so.
    if ( QQuickStyle::name() != QStringLiteral( "org.kde.desktop" ) )
    {
        cWarning() << "accounts: Qt Quick Controls style is" << QQuickStyle::name()
                   << "- the page expects org.kde.desktop for its icons, colours and metrics.";
    }

    // Through a lambda, not signal-to-signal: Calamares' nextStatusChanged carries the new
    // value (`void nextStatusChanged( bool )`) and AccountsConfig's does not, and a connection
    // from a signal with fewer arguments to one with more does not compile.
    connect( m_config, &AccountsConfig::nextEnabledChanged, this, [ this ] {
        emit nextStatusChanged( m_config->nextEnabled() );
    } );

    // The page can still move between its two screens on its own — setMode() sends it back to
    // the chooser rather than leave a form disagreeing with the choice above it — and ViewManager
    // only re-reads the navigation state after ITS own back() and next(). Without this, a screen
    // change from inside the page leaves the window's Back and Next describing the screen you
    // just left.
    connect( m_config, &AccountsConfig::stepChanged, this, [ this ] {
        emit nextStatusChanged( m_config->nextEnabled() );
    } );

    // THE OTHER HALF OF "USE ANYWAY" (plan/26 §3): the dialog's accept settles the password,
    // which flips isAtEnd(), and the advance the user asked for with their press of Next is
    // completed here. No guard is needed beyond the signal itself — it is emitted only by
    // acceptWeakPassword(), never by the withdrawals, which clear the flag silently.
    connect( m_config, &AccountsConfig::weakPasswordAccepted, this, [ this ] {
        Calamares::ViewManager::instance()->next();
    } );

    // QML BINDINGS DO NOT RETRANSLATE BY THEMSELVES: a QTranslator swap posts
    // QEvent::LanguageChange, which re-runs QObject::tr() consumers, while a string bound from a
    // C++ property is only re-evaluated when the engine is told to. Same line, same reason, as
    // every other QML module in this installer — this was the one page without it (plan/27 §1).
    CALAMARES_RETRANSLATE( if ( m_widget && m_widget->engine() ) { m_widget->engine()->retranslate(); } );
}

AccountsViewStep::~AccountsViewStep()
{
    if ( m_widget && m_widget->parent() == nullptr )
    {
        m_widget->deleteLater();
    }
}

QString
AccountsViewStep::prettyName() const
{
    return tr( "Accounts" );
}

QString
AccountsViewStep::prettyStatus() const
{
    return m_config->prettyStatus();
}

QWidget*
AccountsViewStep::widget()
{
    if ( !m_widget )
    {
        m_widget = new QQuickWidget();
        m_widget->setResizeMode( QQuickWidget::SizeRootObjectToView );
        // The name QML binds to. A context property rather than a registered type because there
        // is exactly one of these and the QML never constructs it.
        m_widget->rootContext()->setContextProperty( QStringLiteral( "accounts" ), m_config );
        // qrc:, not a file path: the QML is a resource compiled into this plugin, so there is no
        // second install path and no search order to get wrong (plan/21 §2).
        m_widget->setSource( QUrl( QStringLiteral( "qrc:/accounts/qml/Accounts.qml" ) ) );
    }
    return m_widget;
}

bool
AccountsViewStep::isNextEnabled() const
{
    // Mode-dependent, and that is the change this module makes to a rule the rest of the
    // installer still obeys. Local and domain mode gate on field validity only; managed mode
    // gates on an enrolment that has actually happened, because it creates no local account and
    // an install that completes without one is a disk nobody can log into (plan/21 §3).
    return m_config->nextEnabled();
}

bool
AccountsViewStep::isBackEnabled() const
{
    return true;
}

bool
AccountsViewStep::isAtBeginning() const
{
    // THESE FOUR FUNCTIONS ARE THE WHOLE OF THE TWO-SCREEN WIRING, and none of them is ours:
    // ViewManager::back() calls step->back() instead of leaving the module whenever
    // isAtBeginning() is false, and ViewManager::next() calls step->next() instead of advancing
    // whenever isAtEnd() is false (ViewManager.cpp). So the window's own Back and Next move
    // between the choice and the fields, the sidebar still shows one entry, and Back on the
    // first screen goes to the partition page exactly as it always did.
    //
    // WHILE KEEPING (plan/33 §8) there is only the one screen, so both ends of the pager are
    // true at once: Back leaves for the disk page and Next leaves for applications, neither
    // visiting a chooser or fields screen that Accounts.qml is not even drawing.
    return m_config->keeping() || m_config->onChooser();
}

bool
AccountsViewStep::isAtEnd() const
{
    // THE FIELDS SCREEN, AND A SETTLED PASSWORD (plan/26 §3). The first half is the pager's own
    // rule; the second is the disk page's confirmation worn one screen later — a complete
    // password that fails libpwquality is the one state in which the window's Next opens the
    // weak-password prompt instead of leaving. Managed mode is always settled here; its gate is
    // the enrolment, and nextEnabled() is where it is held.
    return m_config->keeping() || ( m_config->onFields() && m_config->passwordSettled() );
}

void
AccountsViewStep::onActivate()
{
    // Read on EVERY activation, not just the first — this page can be reached with `keeping`
    // already true (forward from the disk page after ticking Keep) or reached again after Back
    // (the disk page changed which disk is selected, or the tick, since this page was last on
    // screen) — and it must never go stale in either direction (plan/33 §8).
    Calamares::GlobalStorage* gs = Calamares::JobQueue::instance()->globalStorage();
    m_config->setKeeping( gs && gs->value( QStringLiteral( "diskKeepData" ) ).toBool() );
}

void
AccountsViewStep::back()
{
    m_config->goToChooser();
}

void
AccountsViewStep::next()
{
    if ( m_config->onChooser() )
    {
        m_config->goToFields();
        return;
    }
    // On the fields screen, the only reason ViewManager landed here instead of advancing is the
    // unsettled password. The config asks, and emits only when the password is genuinely the
    // one thing in the way — any other arrival is a state the button should already have
    // refused, and standing still is the honest answer to it.
    m_config->requestPasswordConfirmation();
}

Calamares::JobList
AccountsViewStep::jobs() const
{
    return Calamares::JobList();
}

void
AccountsViewStep::onLeave()
{
    // onLeave() fires on the way BACK as well as forward, and Calamares gives a ViewStep no way
    // to tell the two apart. Publishing in both directions is harmless — the sequence re-enters
    // this page before it can reach the exec phase, and onLeave() runs again — and it is why
    // releasing an abandoned enrolment is done from the property setters (editing the code,
    // changing the mode) rather than here: doing it here would release the device every time
    // somebody stepped back to check the keyboard layout.
    Calamares::GlobalStorage* gs = Calamares::JobQueue::instance()->globalStorage();
    m_config->publish( gs );
}

void
AccountsViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_config->setConfigurationMap( configurationMap );
}

#include "moc_AccountsViewStep.cpp"
