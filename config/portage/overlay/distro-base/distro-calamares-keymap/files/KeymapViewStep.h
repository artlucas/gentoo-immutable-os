/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The installer's keyboard step (plan/28 §6).
 *
 * WHY IT IS NOT CALLED `keyboard`. calamares_add_plugin installs a viewmodule into
 * <libdir>/calamares/modules/<name>/, so a plugin of that name would collide file-for-file with
 * app-admin/calamares' own and be blocked by Portage — and ModuleManager takes the FIRST
 * module.desc it finds for a name across modules-search. The directory is `keymap`; the sidebar
 * says "Keyboard".
 *
 * THE JOB IS SOMEBODY ELSE'S, as the location page's is. Upstream's keyboard module carries
 * SetKeyboardLayoutJob, which writes /etc/vconsole.conf and /etc/X11/xorg.conf.d/00-keyboard.conf
 * in the target and resolves a console keymap through a kbd-model-map compiled into Calamares'
 * QRC. That work is `keyboardsetup`'s now, in config/calamares/local-modules, where the map is a
 * data file beside the script rather than a resource inside a binary.
 */
#pragma once

#include "DllMacro.h"
#include "utils/PluginFactory.h"
#include "viewpages/ViewStep.h"

#include <QObject>
#include <QVariantMap>

class KeymapConfig;
class QQuickWidget;

class PLUGINDLLEXPORT KeymapViewStep : public Calamares::ViewStep
{
    Q_OBJECT

public:
    explicit KeymapViewStep( QObject* parent = nullptr );
    ~KeymapViewStep() override;

    QString prettyName() const override;
    /*! What the summary page shows: the layout, and the variant if there is one. */
    QString prettyStatus() const override;
    QWidget* widget() override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;
    bool isAtBeginning() const override;
    bool isAtEnd() const override;

    /*! Empty. Writing the target's keymap is `keyboardsetup`'s — see the header. */
    Calamares::JobList jobs() const override;

    void onLeave() override;
    void setConfigurationMap( const QVariantMap& configurationMap ) override;

private:
    KeymapConfig* m_config;
    QQuickWidget* m_widget = nullptr;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( KeymapViewStepFactory )
