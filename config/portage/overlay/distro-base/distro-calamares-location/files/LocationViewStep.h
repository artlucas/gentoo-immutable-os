/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The installer's location step (plan/28 §6).
 *
 * WHY IT IS NOT CALLED `locale`. calamares_add_plugin installs a viewmodule into
 * <libdir>/calamares/modules/<name>/, so a plugin of that name would collide file-for-file with
 * app-admin/calamares' own and be blocked by Portage — and ModuleManager takes the FIRST
 * module.desc it finds for a name across modules-search. The directory is `location`; the sidebar
 * says "Location", which is also what the page asks about, because this module drops the locale
 * half of the stock page entirely (LocationConfig.h says why at length).
 *
 * THE JOB IS SOMEBODY ELSE'S. Upstream's `locale` module is a view step AND a job: its only job
 * is SetTimezoneJob, which re-symlinks /etc/localtime in the target. That is four lines of
 * Python, and this repo already has four job modules written in it, so the work moved to
 * `localesetup` in config/calamares/local-modules — which is also what lets this page contribute
 * no job at all and publish a GlobalStorage key instead, the arrangement every other page here
 * uses.
 */
#pragma once

#include "DllMacro.h"
#include "utils/PluginFactory.h"
#include "viewpages/ViewStep.h"

#include <QObject>
#include <QVariantMap>

class LocationConfig;
class QQuickWidget;

class PLUGINDLLEXPORT LocationViewStep : public Calamares::ViewStep
{
    Q_OBJECT

public:
    explicit LocationViewStep( QObject* parent = nullptr );
    ~LocationViewStep() override;

    QString prettyName() const override;
    /*! What the summary page shows: the zone and its current offset. */
    QString prettyStatus() const override;
    QWidget* widget() override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;
    bool isAtBeginning() const override;
    bool isAtEnd() const override;

    /*! Empty. The symlink is `localesetup`'s, in the exec phase — see the header. */
    Calamares::JobList jobs() const override;

    void onLeave() override;
    void setConfigurationMap( const QVariantMap& configurationMap ) override;

private:
    LocationConfig* m_config;
    QQuickWidget* m_widget = nullptr;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( LocationViewStepFactory )
