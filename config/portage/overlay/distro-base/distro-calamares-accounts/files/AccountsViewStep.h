/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The installer's accounts page (plan/21).
 *
 * WHY THIS IS C++ AND THE JOB IS NOT. Calamares accepts only C++ QtPlugin view modules —
 * ModuleFactory.cpp:53 — so a page cannot be a script, and that is the entire reason this file
 * exists. The WORK is a python job like the three this project already ships (imagedeploy,
 * imagebootloader, imageidentity), because a job CAN be a script and there is no reason to write
 * one in C++ that would then have to be rebuilt against Calamares' ABI.
 *
 * This file is deliberately thin: the widget is a QQuickWidget, the state is AccountsConfig, and
 * everything a reader wants to know about the page's behaviour is in that class or in the QML.
 * What is here is only the four things a ViewStep owes Calamares — a name, a widget, whether Next
 * may be pressed, and what to leave in GlobalStorage on the way out — plus prettyStatus(), which
 * is how the summary page learns what was decided.
 *
 * THIS PAGE CAN BLOCK NEXT, AND ITS PREDECESSOR COULD NOT. ManagedViewStep::isNextEnabled()
 * returned true unconditionally, on plan/18 §7.4's rule that an unreachable service must never
 * fail an install. That rule stands for local and domain mode and is withdrawn for managed mode,
 * because managed mode creates no local account: see plan/21 §3, which is the whole argument.
 */
#pragma once

#include "DllMacro.h"
#include "utils/PluginFactory.h"
#include "viewpages/ViewStep.h"

#include <QObject>
#include <QVariantMap>

class AccountsConfig;
class QQuickWidget;

class PLUGINDLLEXPORT AccountsViewStep : public Calamares::ViewStep
{
    Q_OBJECT

public:
    explicit AccountsViewStep( QObject* parent = nullptr );
    ~AccountsViewStep() override;

    QString prettyName() const override;
    /*! What the summary page shows: the decision, in the chosen mode's own terms. */
    QString prettyStatus() const override;
    QWidget* widget() override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;
    bool isAtBeginning() const override;
    bool isAtEnd() const override;
    void back() override;
    void next() override;

    /*! Reads GlobalStorage's diskKeepData into the config every time this page is SHOWN — going
     *  forward from the disk page, or back from applications — so a tick changed after this page
     *  was last on screen (Back to the disk page, un-tick, forward again) is never stale (plan/33
     *  §8). Calamares' own ViewStep::onActivate() is a no-op the base class already defines, so
     *  this is the first override this file has needed for it. */
    void onActivate() override;

    /*! Empty, always. Creating the account, joining the domain and transplanting the enrolment
     *  are the `accountsetup` python job's work. */
    Calamares::JobList jobs() const override;

    void onLeave() override;
    void setConfigurationMap( const QVariantMap& configurationMap ) override;

private:
    AccountsConfig* m_config;
    QQuickWidget* m_widget = nullptr;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( AccountsViewStepFactory )
