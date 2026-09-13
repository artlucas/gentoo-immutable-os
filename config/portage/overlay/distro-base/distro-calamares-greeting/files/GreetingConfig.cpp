/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "GreetingConfig.h"

#include "Branding.h"
#include "modulesystem/ModuleManager.h"
#include "modulesystem/RequirementsModel.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QSortFilterProxyModel>

GreetingConfig::GreetingConfig( QObject* parent )
    : QObject( parent )
    , m_filtermodel( new QSortFilterProxyModel( this ) )
{
    // The macro connects the slot AND runs it once, which is what gives warningMessage() a value
    // before anything reads it.
    CALAMARES_RETRANSLATE_SLOT( &GreetingConfig::retranslate );

    auto* manager = Calamares::ModuleManager::instance();
    auto* model = manager ? manager->requirementsModel() : nullptr;
    if ( model )
    {
        // ModuleManager::checkRequirements() re-arms a five-second timer for as long as a
        // mandatory requirement is unmet, so attaching a bigger disk really does clear this page
        // without restarting the installer — but only if the sentence above the list is recomputed
        // when it happens. This is the connection that does that.
        connect( model, &Calamares::RequirementsModel::satisfiedMandatoryChanged, this, [ this ]( bool )
                 { retranslate(); } );
        connect( model, &Calamares::RequirementsModel::satisfiedRequirementsChanged, this, [ this ]( bool )
                 { retranslate(); } );
    }
    else
    {
        cWarning() << "greeting: no requirements model, so the page cannot report a verdict.";
    }
}

Calamares::RequirementsModel*
GreetingConfig::requirementsModel() const
{
    auto* manager = Calamares::ModuleManager::instance();
    return manager ? manager->requirementsModel() : nullptr;
}

QAbstractItemModel*
GreetingConfig::unsatisfiedRequirements() const
{
    if ( !m_filtermodel->sourceModel() )
    {
        // Upstream's filter, kept exactly: the Satisfied role is a bool, and a proxy asked to
        // match the fixed string "false" against it keeps the rows that failed.
        m_filtermodel->setFilterRole( Calamares::RequirementsModel::Roles::Satisfied );
        m_filtermodel->setFilterFixedString( QStringLiteral( "false" ) );
        m_filtermodel->setSourceModel( requirementsModel() );
    }
    return m_filtermodel;
}

void
GreetingConfig::retranslate()
{
    const auto* branding = Calamares::Branding::instance();
    const QString name = branding ? branding->shortVersionedName() : QString();
    const auto* model = requirementsModel();

    // Unknown is not "fine". Before the first round of checks finishes there is no model state to
    // report — but the box is showing its spinner then and this string is not on screen, so the
    // optimistic branch costs nothing and saves a third state nobody would see.
    m_warningMessage = ( model && !model->satisfiedMandatory() )
        ? tr( "This computer cannot install %1." ).arg( name )
        : tr( "This computer can install %1." ).arg( name );

    emit warningMessageChanged( m_warningMessage );
}

#include "moc_GreetingConfig.cpp"
