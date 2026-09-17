/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "GreetingConfig.h"

#include "Branding.h"
#include "modulesystem/ModuleManager.h"
#include "modulesystem/RequirementsModel.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QAbstractItemModel>

GreetingConfig::GreetingConfig( QObject* parent )
    : QObject( parent )
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
                 { markChecked(); retranslate(); } );
        connect( model, &Calamares::RequirementsModel::satisfiedRequirementsChanged, this, [ this ]( bool )
                 { markChecked(); retranslate(); } );

        // THE MODEL IS RESET, NOT UPDATED, when a round of checks lands: addRequirementsList()
        // calls beginResetModel(). Neither verdict signal fires when the answer has not moved —
        // a second round that agrees with the first emits nothing — so the page would sit on its
        // spinner forever on a machine that passed everything the first time. This is the signal
        // that always fires, and it is what `checked` is really watching.
        connect( model, &QAbstractItemModel::modelReset, this, [ this ]
                 { markChecked(); retranslate(); } );
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
GreetingConfig::requirementsModelForQml() const
{
    return requirementsModel();
}

void
GreetingConfig::markChecked()
{
    if ( m_checked )
    {
        return;
    }
    m_checked = true;
    emit checkedChanged( true );
}

QString
GreetingConfig::pageTitle() const
{
    // NOT translatable: it is a product name and a version number, and both come out of
    // config/calamares/branding/installer/branding.desc.
    const auto* branding = Calamares::Branding::instance();
    return branding ? branding->versionedName() : QString();
}

QString
GreetingConfig::pageLede() const
{
    const auto* branding = Calamares::Branding::instance();
    return tr( "This program will ask you a few questions and then install %1 on this computer. "
               "Everything already on the disk you choose will be erased." )
        .arg( branding ? branding->productName() : QString() );
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
    emit retranslated();
}

#include "moc_GreetingConfig.cpp"
