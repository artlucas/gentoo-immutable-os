/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The installer's summary step (plan/28 §6).
 *
 * WHY IT IS NOT CALLED `summary`. calamares_add_plugin installs a viewmodule into
 * <libdir>/calamares/modules/<name>/, so a plugin of that name would collide file-for-file with
 * app-admin/calamares' own and be blocked by Portage — and ModuleManager takes the FIRST
 * module.desc it finds for a name across modules-search, which would make which of the two you
 * got depend on the order of a list in settings.conf. The directory is `review`; the sidebar says
 * "Summary", because that is a word for a reader and not a filename.
 *
 * WHAT IT REPLACES, AND WHY. The stock summary page renders each preceding step's
 * prettyDescription() into a QWidget list. Two things follow from that which this installer does
 * not want: the list is drawn in Breeze, beside eight pages that are not; and the page it draws
 * is a stack of headings and paragraphs, where what this installer has to show before a
 * whole-disk erase is a table of decisions and the name of the disk.
 *
 * NOTHING IS PUBLISHED FROM HERE. This page writes no GlobalStorage key and contributes no job:
 * it is the last screen before the exec phase and it reads.
 */
#pragma once

#include "DllMacro.h"
#include "utils/PluginFactory.h"
#include "viewpages/ViewStep.h"

#include <QObject>
#include <QVariantMap>

class ReviewConfig;
class QQuickWidget;

class PLUGINDLLEXPORT ReviewViewStep : public Calamares::ViewStep
{
    Q_OBJECT

public:
    explicit ReviewViewStep( QObject* parent = nullptr );
    ~ReviewViewStep() override;

    QString prettyName() const override;
    QWidget* widget() override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;
    bool isAtBeginning() const override;
    bool isAtEnd() const override;

    /*! Empty, always: this page reads. */
    Calamares::JobList jobs() const override;

    /*! THE ONE REASON THIS CLASS EXISTS BEYOND BOILERPLATE. Every row is another step's
     *  prettyStatus(), and those change while the user walks back and forth — so they are
     *  collected on every entry and never cached. A summary that disagreed with the page behind
     *  it would be wrong on the one screen where being wrong costs somebody a disk. */
    void onActivate() override;

    void setConfigurationMap( const QVariantMap& configurationMap ) override;

private:
    ReviewConfig* m_config;
    QQuickWidget* m_widget = nullptr;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( ReviewViewStepFactory )
