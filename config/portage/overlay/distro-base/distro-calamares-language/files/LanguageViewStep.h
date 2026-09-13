/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The installer's first step (plan/22).
 *
 * WHY THIS REPLACES STOCK `welcome` RATHER THAN CONFIGURING IT. The order of that page is in its
 * C++: WelcomePage.cpp inserts the requirements checker at `welcome_text_idx + 1`, above the
 * language row, and when every check passes ResultsListWidget::requirementsComplete() deletes the
 * results list and puts an EXPANDING branding logo in its place. So on a healthy machine the
 * language picker is a closed combo box under two sentences of English and a logo sized to fill
 * the rest of the window. No configuration key reaches any of that.
 *
 * And it cannot be a QML file dropped into the branding directory either, which is the route that
 * would have needed no package at all. Two mechanical reasons, both in plan/22 §3: the model
 * upstream hands a page exposes no locale id, so the list cannot be curated; and
 * QmlViewStep::setConfigurationMap() starts compiling QML the moment the module loads, which —
 * since ModuleManager::loadModules() walks the sequence in order and this is the first entry —
 * happens before AccountsViewStep's constructor runs. QQuickStyle::setStyle() is silently ignored
 * once anything has imported Qt Quick Controls, and the accounts page would lose Breeze's
 * colours, Breeze's metrics and every icon together.
 *
 * WHICH IS WHY THE STYLE IS SET HERE. Being first in the sequence makes this module the correct
 * owner of that call, not a new hazard. The accounts page keeps its own guard and its warning
 * unchanged, where they become the canary for a future module inserted ahead of this one.
 *
 * ONE SCREEN AND ONE QUESTION, since plan/23. The greeting, the requirements verdict and the six
 * checks behind it are the `greeting` module's — so this step no longer implements
 * checkRequirements(), and isAtBeginning()/isAtEnd() are plain `true` rather than a report on
 * which of two screens is showing.
 */
#pragma once

#include "DllMacro.h"
#include "utils/PluginFactory.h"
#include "viewpages/ViewStep.h"

#include <QObject>
#include <QVariantMap>

class LanguageConfig;
class QQuickWidget;

class PLUGINDLLEXPORT LanguageViewStep : public Calamares::ViewStep
{
    Q_OBJECT

public:
    explicit LanguageViewStep( QObject* parent = nullptr );
    ~LanguageViewStep() override;

    QString prettyName() const override;
    /*! The chosen language, in its own name — what the summary page shows. */
    QString prettyStatus() const override;
    QWidget* widget() override;

    bool isNextEnabled() const override;
    bool isBackEnabled() const override;
    bool isAtBeginning() const override;
    bool isAtEnd() const override;

    /*! Empty, always. This page asks a question and writes one GlobalStorage key; the locale
     *  module and `imageidentity` are what act on it. */
    Calamares::JobList jobs() const override;

    void onLeave() override;
    void setConfigurationMap( const QVariantMap& configurationMap ) override;

private:
    LanguageConfig* m_config;
    QQuickWidget* m_widget = nullptr;
};

CALAMARES_PLUGIN_FACTORY_DECLARATION( LanguageViewStepFactory )
