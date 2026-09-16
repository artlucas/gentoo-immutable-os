/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The installer's applications page (plan/25).
 *
 * WHY THIS IS C++ AND THE WORK IS NOT, one more time and for the same reason the disk page gives:
 * Calamares accepts only C++ QtPlugin view modules (ModuleFactory.cpp:53), so a page cannot be a
 * script. The JOB is `appsetup`, an ordinary python module in config/calamares/local-modules —
 * because a job CAN be a script, and running `flatpak` in a chroot is not a reason to compile
 * anything against Calamares' ABI.
 *
 * WHAT THIS PAGE ASKS, and it is the installer's only question that is allowed to go unanswered
 * the way it stands: which extra applications to add from Flathub — the typical set, nothing, or
 * a chosen list. Offline, the question collapses to its own second answer: nothing can be added
 * without a connection, so the page says so and pre-answers "nothing extra", and the install is
 * none the worse for it (the payload's own applications are already on the disk).
 *
 * This file is deliberately thin, like its four siblings: a name, a widget, whether Next may be
 * pressed, what to leave in GlobalStorage, and what the summary page should say. Everything about
 * the page's behaviour is in AppsConfig or in the QML.
 */
#pragma once

#include "DllMacro.h"
#include "utils/PluginFactory.h"
#include "viewpages/ViewStep.h"

#include <QObject>
#include <QVariantMap>

class AppsConfig;
class QQuickWidget;

class PLUGINDLLEXPORT AppsViewStep : public Calamares::ViewStep
{
    Q_OBJECT

public:
    explicit AppsViewStep( QObject* parent = nullptr );
    ~AppsViewStep() override;

    QString prettyName() const override;
    /*! What the summary page shows: the choice, in the words the page offered it in. */
    QString prettyStatus() const override;
    QWidget* widget() override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;
    bool isAtBeginning() const override;
    bool isAtEnd() const override;

    /*! Empty, always. Installing Flatpaks is the `appsetup` job's work, in the exec phase, where
     *  the network verdict is minutes fresher than anything a page could have asked for. */
    Calamares::JobList jobs() const override;

    /*! THE ONE REASON THIS CLASS EXISTS BEYOND BOILERPLATE. onActivate() re-asks the internet
     *  question every time the page is entered, including from the summary page's Back — the
     *  greeting page's verdict was taken once at startup, and "the network came up while somebody
     *  was choosing a keyboard layout" is the exact case it cannot see. */
    void onActivate() override;

    void onLeave() override;
    void setConfigurationMap( const QVariantMap& configurationMap ) override;

private:
    AppsConfig* m_config;
    QQuickWidget* m_widget = nullptr;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( AppsViewStepFactory )
