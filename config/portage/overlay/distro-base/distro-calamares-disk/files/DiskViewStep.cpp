/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "DiskViewStep.h"

#include "DiskConfig.h"

#include "GlobalStorage.h"
#include "JobQueue.h"
#include "ViewManager.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QQmlContext>
#include <QQmlEngine>
#include <QQuickStyle>
#include <QQuickWidget>
#include <QUrl>

CALAMARES_PLUGIN_FACTORY_DEFINITION( DiskViewStepFactory, registerPlugin< DiskViewStep >(); )

DiskViewStep::DiskViewStep( QObject* parent )
    : Calamares::ViewStep( parent )
    , m_config( new DiskConfig( this ) )
{
    // NO QQuickStyle::setStyle() HERE, and its absence is asserted by tests/test-installer.sh.
    // The call is silently ignored once anything has imported QtQuick.Controls, so it belongs to
    // whichever module ModuleManager loads first — the language page, which is the first entry in
    // settings.conf's sequence and says so at length. A second call here would look like it was
    // doing something and would be dead code.
    if ( QQuickStyle::name() != QStringLiteral( "org.kde.desktop" ) )
    {
        cWarning() << "disk: Qt Quick Controls style is" << QQuickStyle::name()
                   << "- this page expects org.kde.desktop for its icons, colours and metrics.";
    }

    // QML BINDINGS DO NOT RETRANSLATE BY THEMSELVES: a QTranslator swap posts
    // QEvent::LanguageChange, which re-runs QObject::tr() consumers, while a qsTr() inside a QML
    // binding is only re-evaluated when the engine is told to. Same line, same reason, as
    // LanguageViewStep and Slideshow.cpp:57.
    CALAMARES_RETRANSLATE( if ( m_widget && m_widget->engine() ) { m_widget->engine()->retranslate(); } );

    // Through a lambda rather than signal-to-signal: Calamares' nextStatusChanged carries the new
    // value and DiskConfig's does not, and a connection from a signal with fewer arguments to one
    // with more does not compile.
    connect( m_config, &DiskConfig::nextEnabledChanged, this, [ this ] {
        emit nextStatusChanged( m_config->nextEnabled() );
    } );

    // THE OTHER HALF OF "ERASE AND INSTALL": accepting the dialog sets confirmed, which flips
    // isAtEnd(), and the advance the user asked for with their press of Next is completed here.
    // The guard is the whole safety of it — confirmed is also set to false (on leaving, on a disk
    // change), and those clears must never move the window.
    connect( m_config, &DiskConfig::confirmedChanged, this, [ this ] {
        if ( m_config->confirmed() )
        {
            Calamares::ViewManager::instance()->next();
        }
    } );
}

DiskViewStep::~DiskViewStep()
{
    if ( m_widget && m_widget->parent() == nullptr )
    {
        m_widget->deleteLater();
    }
}

QString
DiskViewStep::prettyName() const
{
    // "Disk", not "Partitions". The sidebar names what the user chooses on each page, and on this
    // one they choose a disk — there is no partition editor behind it and no partition to name.
    return tr( "Disk" );
}

QString
DiskViewStep::prettyStatus() const
{
    return m_config->prettyStatus();
}

QWidget*
DiskViewStep::widget()
{
    if ( !m_widget )
    {
        m_widget = new QQuickWidget();
        m_widget->setResizeMode( QQuickWidget::SizeRootObjectToView );
        m_widget->rootContext()->setContextProperty( QStringLiteral( "disk" ), m_config );
        // qrc:, not a file path — the QML is a resource compiled into this plugin, so there is no
        // second install path and no search order to get wrong (plan/21 §2).
        m_widget->setSource( QUrl( QStringLiteral( "qrc:/disk/qml/Disk.qml" ) ) );
    }
    return m_widget;
}

bool
DiskViewStep::isNextEnabled() const
{
    // A SELECTED DISK, and that is all the button asks. The question the old checkbox used to put
    // in front of the button is asked BY the button now: an unconfirmed press opens the erase
    // dialog rather than leaving, so this is still one of the two steps in this installer that
    // can refuse to advance — it just refuses at the door rather than darkening the handle.
    return m_config->nextEnabled();
}

bool
DiskViewStep::isBackEnabled() const
{
    return true;
}

bool
DiskViewStep::isAtBeginning() const
{
    // ONE SCREEN, so Back is always the window's. The confirmation is not a second screen — it
    // is a dialog — but it uses the same machinery one: ViewManager::next() calls this step's
    // next() instead of advancing whenever isAtEnd() is false, which is what turns a press of
    // Next into the question instead of the erase.
    return true;
}

bool
DiskViewStep::isAtEnd() const
{
    // CONFIRMATION STATE, not screen state: false until the dialog's "Erase and install" has
    // answered, true for exactly the moment it takes to complete the advance (the constructor
    // calls ViewManager::next() when confirmed flips). onLeave() withdraws the answer on the way
    // out, so the next entry into this page finds the question unasked again.
    return m_config->confirmed();
}

void
DiskViewStep::next()
{
    // ViewManager::next() lands here — instead of leaving — for as long as isAtEnd() is false,
    // which is every press that has not already been answered by the dialog. The dialog is drawn
    // by the QML; this side of the boundary only knocks.
    if ( !m_config->confirmed() )
    {
        m_config->requestConfirmation();
    }
}

Calamares::JobList
DiskViewStep::jobs() const
{
    return Calamares::JobList();
}

void
DiskViewStep::onLeave()
{
    // onLeave() fires on the way BACK as well as forward and Calamares gives a ViewStep no way to
    // tell the two apart. Publishing in both directions is harmless here: the keys describe what
    // is currently chosen, and the exec phase is only ever reached through the forward leave that
    // followed an accepted dialog, so diskConfirmed is true when anything reads it. What it must
    // NOT do is anything irreversible — which is why the disk is written by a job in the exec
    // phase and not from here.
    m_config->publish( Calamares::JobQueue::instance()->globalStorage() );
    // WITHDRAW THE ANSWER, in both directions, because the question is asked on every press
    // (plan/26 §1): leaving this page armed would make the next Next a silent one. This also
    // closes a dialog the user abandoned with the window's Back — the QML listens for the clear.
    m_config->setConfirmed( false );
}

void
DiskViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_config->setConfigurationMap( configurationMap );
}

#include "moc_DiskViewStep.cpp"
