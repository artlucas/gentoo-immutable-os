/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The installer's last step (plan/28 §6).
 *
 * WHY IT IS NOT CALLED `finished`. calamares_add_plugin installs a viewmodule into
 * <libdir>/calamares/modules/<name>/, so a plugin of that name would collide file-for-file with
 * app-admin/calamares' own and be blocked by Portage — and ModuleManager takes the FIRST
 * module.desc it finds for a name across modules-search. The directory is `done`; the sidebar
 * says "Finish", because that is a word for a reader and not a filename.
 *
 * WHAT IT KEEPS FROM THE MODULE IT REPLACES. `restartNowMode` and `restartNowCommand`, by their
 * upstream names and with upstream's aliases, and a restart fired on QApplication::aboutToQuit —
 * which is the arrangement rather than a copy of it: the window has to come down before the
 * machine does, and aboutToQuit is the only point where both are true.
 *
 * WHAT IT DROPS. `notifyOnFinished`, upstream's D-Bus desktop notification. It is `false` in this
 * medium's configuration and always has been (config/calamares/modules/finished.conf.in), because
 * a notification about an installer that is the only application on the screen has no second
 * window to be seen from. Dropping it removes a QtDBus dependency and a code path nothing here
 * exercised.
 */
#pragma once

#include "DllMacro.h"
#include "utils/PluginFactory.h"
#include "viewpages/ViewStep.h"

#include <QObject>
#include <QVariantMap>

class DoneConfig;
class QQuickWidget;

class PLUGINDLLEXPORT DoneViewStep : public Calamares::ViewStep
{
    Q_OBJECT

public:
    explicit DoneViewStep( QObject* parent = nullptr );
    ~DoneViewStep() override;

    QString prettyName() const override;
    QWidget* widget() override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;
    bool isAtBeginning() const override;
    bool isAtEnd() const override;

    Calamares::JobList jobs() const override;

    /*! Collects the rows, and arms the restart. */
    void onActivate() override;

    void setConfigurationMap( const QVariantMap& configurationMap ) override;

private:
    DoneConfig* m_config;
    QQuickWidget* m_widget = nullptr;
    /*! aboutToQuit is connected once, not once per entry: this page can be activated again if
     *  somebody walks back into it, and a second connection would run the restart command twice. */
    bool m_quitConnected = false;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( DoneViewStepFactory )
