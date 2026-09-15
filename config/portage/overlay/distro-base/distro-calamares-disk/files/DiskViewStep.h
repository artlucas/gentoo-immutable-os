/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The installer's disk page (plan/24).
 *
 * WHY THIS IS C++ AND THE WORK IS NOT, one more time and for the same reason the accounts page
 * gives: Calamares accepts only C++ QtPlugin view modules (ModuleFactory.cpp:53), so a page
 * cannot be a script. The JOB is `disksetup`, an ordinary python module in
 * config/calamares/local-modules — because a job CAN be a script, and writing a GPT with sfdisk
 * is not a reason to compile anything against Calamares' ABI.
 *
 * WHAT LEFT WHEN THIS ARRIVED. Stock `partition` was in BOTH sequences: its view step drew the
 * page and the same view step's jobs() produced the KPMcore work that wrote the disk. There is no
 * way to replace one half — a view step owns its jobs — so removing the page removes the
 * partitioner, and `disksetup` is what took over. plan/24 §4 is the argument for the shape that
 * replaced it: one shell function, in lib/layout.sh, shared with the pipeline that builds the
 * factory image, instead of a YAML partitionLayout that a test had to keep comparing against it.
 *
 * This file is deliberately thin, like its three siblings: a name, a widget, whether Next may be
 * pressed, what to leave in GlobalStorage, and what the summary page should say. Everything about
 * the page's behaviour is in DiskConfig or in the QML.
 */
#pragma once

#include "DllMacro.h"
#include "utils/PluginFactory.h"
#include "viewpages/ViewStep.h"

#include <QObject>
#include <QVariantMap>

class DiskConfig;
class QQuickWidget;

class PLUGINDLLEXPORT DiskViewStep : public Calamares::ViewStep
{
    Q_OBJECT

public:
    explicit DiskViewStep( QObject* parent = nullptr );
    ~DiskViewStep() override;

    QString prettyName() const override;
    /*! What the summary page shows: the disk, named the way the user picked it. */
    QString prettyStatus() const override;
    QWidget* widget() override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;
    bool isAtBeginning() const override;
    bool isAtEnd() const override;

    /*! Empty, always. Writing the GPT and making the filesystem are the `disksetup` job's work,
     *  in the exec phase, where a failure can report itself and where Calamares has already
     *  asked its "really install?" question. A view step that partitioned in jobs() would be
     *  doing it before that prompt. */
    Calamares::JobList jobs() const override;

    void onLeave() override;
    void setConfigurationMap( const QVariantMap& configurationMap ) override;

private:
    DiskConfig* m_config;
    QQuickWidget* m_widget = nullptr;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( DiskViewStepFactory )
