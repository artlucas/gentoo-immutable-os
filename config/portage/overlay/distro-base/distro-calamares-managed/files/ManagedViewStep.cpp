/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "ManagedViewStep.h"

#include "ManagedPage.h"

#include "GlobalStorage.h"
#include "JobQueue.h"

CALAMARES_PLUGIN_FACTORY_DEFINITION( ManagedViewStepFactory, registerPlugin< ManagedViewStep >(); )

ManagedViewStep::ManagedViewStep( QObject* parent )
    : Calamares::ViewStep( parent )
    , m_widget( new ManagedPage() )
{
}

ManagedViewStep::~ManagedViewStep()
{
    if ( m_widget && m_widget->parent() == nullptr )
    {
        m_widget->deleteLater();
    }
}

QString
ManagedViewStep::prettyName() const
{
    return tr( "Organisation" );
}

QWidget*
ManagedViewStep::widget()
{
    return m_widget;
}

bool
ManagedViewStep::isNextEnabled() const
{
    // ALWAYS. Nothing on this page may block the install: an unreachable control plane, an
    // expired code and a person who simply does not want to enrol are the same thing here, and
    // all three must be able to press Next (plan/19 §7.3, plan/18 §7.4).
    return true;
}

bool
ManagedViewStep::isBackEnabled() const
{
    return true;
}

bool
ManagedViewStep::isAtBeginning() const
{
    return true;
}

bool
ManagedViewStep::isAtEnd() const
{
    return true;
}

Calamares::JobList
ManagedViewStep::jobs() const
{
    return Calamares::JobList();
}

void
ManagedViewStep::onLeave()
{
    // Published to GlobalStorage on the way out, which is the whole contract with the
    // `managedenroll` python job. Calamares' own Active Directory page keeps its fields as
    // private Config members and publishes nothing (plan/18 §7.1) — which is exactly why that
    // feature needed a /usr/bin/realm shim and this one does not.
    Calamares::GlobalStorage* gs = Calamares::JobQueue::instance()->globalStorage();
    if ( !gs )
    {
        return;
    }

    gs->insert( QStringLiteral( "managedEnrollmentRequested" ), m_widget->isEnrolmentRequested() );
    // The code is written unconditionally when one was typed, even if the box was then
    // unticked, so the job's own check is the single decision point rather than two that can
    // disagree.
    gs->insert( QStringLiteral( "managedEnrollmentCode" ),
                m_widget->isEnrolmentRequested() ? m_widget->code() : QString() );
    gs->insert( QStringLiteral( "managedDeviceName" ), m_widget->deviceName() );
}

void
ManagedViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    // One optional key, `organisationHint`: a shop imaging six machines can put its own name on
    // the page through the branding it already ships, so the person in front of it recognises
    // what they are being asked to join.
    const QString hint = configurationMap.value( QStringLiteral( "organisationHint" ) ).toString();
    m_widget->setOrganisationHint( hint );
}

#include "moc_ManagedViewStep.cpp"
