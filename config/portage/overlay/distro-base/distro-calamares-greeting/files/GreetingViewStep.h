/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The installer's second step: the greeting and the requirements verdict (plan/23).
 *
 * WHY IT IS A MODULE AND NOT A SECOND SCREEN. It was a second screen — LanguageViewStep answered
 * isAtBeginning()/isAtEnd() with which of two screens was showing, and the window's own Back and
 * Next moved between them. That works, and it is what the accounts page still does, but it is
 * wrong here for a reason the accounts page does not have: a view step is ONE entry in the
 * sidebar. The installer's first two questions — what language, and may we erase this disk —
 * appeared as a single step called "Language", the greeting could not be reached from the sidebar
 * at all, and the progress the sidebar reports was off by one for the rest of the install.
 *
 * WHY IT IS NOT CALLED `welcome`. calamares_add_plugin installs a viewmodule into
 * <libdir>/calamares/modules/<name>/, so a plugin of that name would collide file-for-file with
 * app-admin/calamares' own welcome module and be blocked by Portage — and ModuleManager takes the
 * FIRST module.desc it finds for a given name across modules-search, which would make which of the
 * two you got depend on the order of a list in settings.conf. The directory is `greeting`; the
 * sidebar says "Welcome", because that is a word for a reader and not a filename.
 *
 * WHAT IT OWNS. The six requirement checks, because a requirement is contributed by whichever
 * module is in the sequence (Module::checkRequirements) and this is the module that draws the
 * verdict. They moved here from the language module with the screen that displayed them.
 */
#pragma once

#include "DllMacro.h"
#include "modulesystem/Requirement.h"
#include "utils/PluginFactory.h"
#include "viewpages/ViewStep.h"

#include <QObject>
#include <QVariantMap>

class GreetingConfig;
class GreetingPage;
class Requirements;

class PLUGINDLLEXPORT GreetingViewStep : public Calamares::ViewStep
{
    Q_OBJECT

public:
    explicit GreetingViewStep( QObject* parent = nullptr );
    ~GreetingViewStep() override;

    QString prettyName() const override;
    QWidget* widget() override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;
    bool isAtBeginning() const override;
    bool isAtEnd() const override;

    /*! Empty, always. This page states a verdict; it changes nothing. */
    Calamares::JobList jobs() const override;

    /*! The six checks (Requirements). */
    Calamares::RequirementsList checkRequirements() override;

    void setConfigurationMap( const QVariantMap& configurationMap ) override;

private:
    Requirements* m_requirements;
    GreetingConfig* m_config;
    GreetingPage* m_widget = nullptr;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( GreetingViewStepFactory )
