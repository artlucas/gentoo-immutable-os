/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The installer page for managed enrolment (plan/19 §7.3, Phase D).
 *
 * WHY THIS IS C++ AND THE JOB IS NOT. Calamares accepts only C++ QtPlugin view modules —
 * ModuleFactory.cpp:53 — so a page cannot be a script, and that is the entire reason this file
 * exists. The WORK, though, is a python job like the three this project already ships
 * (imagedeploy, imagebootloader, imageidentity), because a job can be a script and there is no
 * reason to write one in C++ that would then have to be rebuilt against Calamares' ABI.
 *
 * So the split is: this page collects a code and publishes it to GlobalStorage; the
 * `managedenroll` python job reads it back and runs `<id>-managed enroll --root`. plan/18 §7.1
 * recorded that Calamares' own Active Directory page does NOT publish its fields to
 * GlobalStorage, which is what forced the `realm` shim; this page is ours, so it can.
 *
 * AND IT MUST NOT FAIL THE INSTALL. plan/18 §7.4's lesson, inherited whole: a control plane that
 * is unreachable while someone installs a machine is a Tuesday. Nothing here validates a code
 * against the network, nothing here blocks *next*, and the job that follows exits 0 whatever
 * happens — recording what was asked for so `<id>-managed status` can say why it did not happen.
 */
#pragma once

#include "DllMacro.h"
#include "utils/PluginFactory.h"
#include "viewpages/ViewStep.h"

#include <QObject>
#include <QVariantMap>

class ManagedPage;

class PLUGINDLLEXPORT ManagedViewStep : public Calamares::ViewStep
{
    Q_OBJECT

public:
    explicit ManagedViewStep( QObject* parent = nullptr );
    ~ManagedViewStep() override;

    QString prettyName() const override;
    QWidget* widget() override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;
    bool isAtBeginning() const override;
    bool isAtEnd() const override;

    /*! Empty, always. The enrolment is the `managedenroll` python job's work; a C++ job here
     *  would have to be rebuilt against Calamares' ABI for no gain. */
    Calamares::JobList jobs() const override;

    void onLeave() override;
    void setConfigurationMap( const QVariantMap& configurationMap ) override;

private:
    ManagedPage* m_widget;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( ManagedViewStepFactory )
