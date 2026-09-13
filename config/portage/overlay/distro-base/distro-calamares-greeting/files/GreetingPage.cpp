/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "GreetingPage.h"

#include "GreetingConfig.h"
#include "checker/CheckerContainer.h"

#include "Branding.h"
#include "modulesystem/ModuleManager.h"
#include "modulesystem/RequirementsModel.h"
#include "utils/Gui.h"
#include "utils/Retranslator.h"

#include <QBoxLayout>
#include <QFont>
#include <QLabel>
#include <QPalette>

GreetingPage::GreetingPage( GreetingConfig* config, QWidget* parent )
    : QWidget( parent )
    , m_config( config )
    , m_heading( new QLabel( this ) )
    , m_subtitle( new QLabel( this ) )
    , m_mainText( new QLabel( this ) )
    , m_checker( new CheckerContainer( config, this ) )
{
    const int fontHeight = Calamares::defaultFontHeight();

    auto* layout = new QVBoxLayout( this );
    layout->setContentsMargins( fontHeight, fontHeight, fontHeight, fontHeight );
    layout->setSpacing( 0 );

    // The product, in the branding's own words. Not translatable: versionedName is a name and a
    // version number, and both come out of config/calamares/branding/installer/branding.desc.
    QFont headingFont = m_heading->font();
    headingFont.setPointSize( Calamares::defaultFontSize() + 4 );
    headingFont.setBold( true );
    m_heading->setFont( headingFont );
    m_heading->setWordWrap( true );
    layout->addWidget( m_heading );

    QFont subtitleFont = m_subtitle->font();
    subtitleFont.setPointSize( Calamares::defaultFontSize() - 1 );
    m_subtitle->setFont( subtitleFont );
    m_subtitle->setWordWrap( true );
    // Dimmed through the palette rather than a hard-coded grey: the sidebar's colours come from
    // branding.desc and the page's do not, so anything painted here has to follow the Qt style or
    // it stops being legible the first time somebody runs the medium under a dark theme.
    QPalette dimmed = m_subtitle->palette();
    dimmed.setColor( QPalette::WindowText, dimmed.color( QPalette::Disabled, QPalette::WindowText ) );
    m_subtitle->setPalette( dimmed );
    layout->addWidget( m_subtitle );

    layout->addSpacing( fontHeight );

    m_mainText->setWordWrap( true );
    m_mainText->setSizePolicy( QSizePolicy::Expanding, QSizePolicy::Preferred );
    layout->addWidget( m_mainText );

    layout->addSpacing( fontHeight );
    layout->addWidget( m_checker );

    CALAMARES_RETRANSLATE_SLOT( &GreetingPage::retranslate );

    // UPSTREAM'S TWO CONNECTIONS, from WelcomePage.cpp, and they are the whole of the box's life
    // cycle: `requirementsComplete` swaps the spinner for the results list (and is emitted again
    // on every five-second re-check), `progressMessageChanged` is what the spinner says while it
    // spins.
    //
    // The ordering they depend on is CalamaresApplication's, not ours:
    // ModuleManager::checkRequirements() is called from initViewSteps(), which runs after
    // modulesLoaded — and every view step's widget() has already been called by then, because
    // ViewManager::insertViewStep() calls it as the step is added. So this page exists before the
    // first round of checks can finish.
    auto* manager = Calamares::ModuleManager::instance();
    if ( manager )
    {
        connect( manager,
                 &Calamares::ModuleManager::requirementsComplete,
                 m_checker,
                 &CheckerContainer::requirementsComplete );
        if ( auto* model = manager->requirementsModel() )
        {
            connect( model,
                     &Calamares::RequirementsModel::progressMessageChanged,
                     m_checker,
                     &CheckerContainer::requirementsProgress );
        }
    }
}

void
GreetingPage::retranslate()
{
    const auto* branding = Calamares::Branding::instance();
    m_heading->setText( branding ? branding->versionedName() : QString() );
    m_subtitle->setText( tr( "Install medium" ) );
    m_mainText->setText( tr( "This program will ask you a few questions and then install %1 on this computer. "
                             "Everything already on the disk you choose will be erased." )
                             .arg( branding ? branding->productName() : QString() ) );
}

#include "moc_GreetingPage.cpp"
