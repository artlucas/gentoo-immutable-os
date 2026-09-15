/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "DiskViewStep.h"

#include "DiskConfig.h"

#include "GlobalStorage.h"
#include "JobQueue.h"
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
    // A SELECTED DISK AND A TICKED BOX, both. This is the second of the two steps in this
    // installer that can refuse to advance — the accounts page is the other — and it refuses for
    // a blunter reason: past this page and its prompt, somebody's disk is rewritten.
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
    // ONE SCREEN. Both are constants, and that is what makes the window's Back and Next leave
    // this module rather than move inside it: ViewManager::back() calls step->back() whenever
    // isAtBeginning() is false, and next() likewise on isAtEnd(). The accounts page is the one
    // module here that answers these with state.
    return true;
}

bool
DiskViewStep::isAtEnd() const
{
    return true;
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
    // is currently chosen, and stepping back to the keyboard page and forward again re-publishes
    // the same three values. What it must NOT do is anything irreversible — which is why the disk
    // is written by a job in the exec phase and not from here.
    m_config->publish( Calamares::JobQueue::instance()->globalStorage() );
}

void
DiskViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_config->setConfigurationMap( configurationMap );
}

#include "moc_DiskViewStep.cpp"
