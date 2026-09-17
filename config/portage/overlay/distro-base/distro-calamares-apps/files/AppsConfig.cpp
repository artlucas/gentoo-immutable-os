/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "AppsConfig.h"

#include "Branding.h"
#include "GlobalStorage.h"
#include "network/Manager.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"

#include <QCoreApplication>

AppsConfig::AppsConfig( QObject* parent )
    : QObject( parent )
{
    CALAMARES_RETRANSLATE_SLOT( &AppsConfig::retranslate );
}

void
AppsConfig::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_apps.clear();
    const QVariantList entries = configurationMap.value( QStringLiteral( "apps" ) ).toList();
    for ( const QVariant& v : entries )
    {
        const QVariantMap e = v.toMap();
        const QString id = e.value( QStringLiteral( "id" ) ).toString().trimmed();
        if ( id.isEmpty() )
        {
            cWarning() << "apps: an entry in the `apps:` list has no id and is skipped.";
            continue;
        }
        QVariantMap out;
        out.insert( QStringLiteral( "id" ), id );
        out.insert( QStringLiteral( "name" ), e.value( QStringLiteral( "name" ) ).toString() );
        out.insert( QStringLiteral( "icon" ), e.value( QStringLiteral( "icon" ) ).toString() );
        // The description is stored raw and translated at read time — see apps() — because its
        // source lives in the conf beside the name it belongs to, not in this file.
        out.insert( QStringLiteral( "description" ),
                    e.value( QStringLiteral( "description" ) ).toString() );
        m_apps.append( out );
    }

    const QString dflt = configurationMap.value( QStringLiteral( "defaultMode" ) ).toString();
    if ( dflt == QLatin1String( "typical" ) || dflt == QLatin1String( "none" ) )
    {
        m_mode = dflt;
    }
    else
    {
        if ( !dflt.isEmpty() && dflt != QLatin1String( "custom" ) )
        {
            cWarning() << "apps: defaultMode" << dflt << "is not one of typical/none; using none.";
        }
        // `custom` is deliberately not a default: a page that opens with the list half-ticked is
        // asking the user to audit six checkboxes before they can trust the one they want. The
        // distro's answer is a set, so the set (or its absence) is what the page opens with.
        m_mode = QStringLiteral( "none" );
    }

    // Custom BEGINS where typical ends, so the only work "choose individually" adds is crossing
    // things off. A custom list that started empty would make the third answer a worse-UX copy of
    // the second, and a user who wanted five of six would tick five boxes for nothing.
    m_selected = allIds();

    if ( m_apps.isEmpty() )
    {
        cError() << "apps: the `apps:` list is empty or unreadable. The page will render but every "
                    "answer installs nothing, which is a configuration failure and not a "
                    "preference.";
    }
}

void
AppsConfig::setMode( const QString& mode )
{
    if ( mode != QLatin1String( "typical" ) && mode != QLatin1String( "none" )
         && mode != QLatin1String( "custom" ) )
    {
        return;
    }
    // The enforcement half of the offline rule; the QML's half is disabling the controls. Written
    // anyway because the QML is not the only caller a settings change could add.
    if ( !m_hasInternet && mode != QLatin1String( "none" ) )
    {
        return;
    }
    if ( mode == m_mode )
    {
        return;
    }
    m_mode = mode;
    emit modeChanged();
}

QVariantList
AppsConfig::selectedIds() const
{
    QVariantList out;
    for ( const QString& id : m_selected )
    {
        out.append( id );
    }
    return out;
}

QVariantList
AppsConfig::apps() const
{
    // m_apps holds the conf's words raw; the description is the one key that translates, and it
    // translates HERE rather than in setConfigurationMap because the language can change after
    // the conf is read. QCoreApplication::translate with a named context — the LanguageNames
    // bargain (LanguageConfig.cpp): a conf-sourced string's translation is looked up by its own
    // text in a context no lupdate ever sees, hand-maintained in the .ts files beside the
    // machine-extracted ones. An untranslated or drifted entry falls back to the English the
    // conf already holds, which is the correct failure (plan/27 §2).
    QVariantList out;
    for ( const QVariant& v : m_apps )
    {
        QVariantMap e = v.toMap();
        e.insert( QStringLiteral( "description" ),
                  QCoreApplication::translate( "AppsDescriptions",
                                               e.value( QStringLiteral( "description" ) )
                                                   .toString()
                                                   .toUtf8()
                                                   .constData() ) );
        out.append( e );
    }
    return out;
}

QString
AppsConfig::headline() const
{
    const auto* branding = Calamares::Branding::instance();
    const QString product
        = branding ? branding->string( Calamares::Branding::ProductName ) : QStringLiteral( "this system" );
    return tr( "Add more applications to %1?" ).arg( product );
}

QString
AppsConfig::subheadline() const
{
    return tr( "These come from Flathub and are installed while the installer runs, so they need "
               "an internet connection. When there is one, the applications already included are "
               "updated to their latest versions too." );
}

QString
AppsConfig::offlineNote() const
{
    return tr( "No internet connection. Nothing can be added from Flathub without one — install "
               "now and add applications later from Discover." );
}

QString
AppsConfig::typicalNames() const
{
    QStringList names;
    for ( const QVariant& v : m_apps )
    {
        names.append( v.toMap().value( QStringLiteral( "name" ) ).toString() );
    }
    return names.join( QStringLiteral( ", " ) );
}

// The labels below are all one-liners and all here for the reason the header's big comment gives:
// the builder's lupdate cannot read QML, so a qsTr() on this page would be English forever. The
// titles are the three radio rows; checkAgainLabel is the button next to the headline, named for
// the same act as the disk page's button so the two pages say one thing.

QString
AppsConfig::checkAgainLabel() const
{
    return tr( "Check again" );
}

QString
AppsConfig::typicalTitle() const
{
    return tr( "Typical set" );
}

QString
AppsConfig::noneTitle() const
{
    return tr( "Nothing extra" );
}

QString
AppsConfig::noneSubtitle() const
{
    return tr( "Only the applications already included" );
}

QString
AppsConfig::customTitle() const
{
    return tr( "Choose individually" );
}

QString
AppsConfig::customSubtitle() const
{
    return tr( "Pick from the list below" );
}

void
AppsConfig::setSelected( const QString& id, bool selected )
{
    const bool known = allIds().contains( id );
    const int at = m_selected.indexOf( id );
    if ( selected ? ( at >= 0 || !known ) : at < 0 )
    {
        return;  // already so, or an id the conf does not carry — see the header
    }
    if ( selected )
    {
        // File order, always, so what publish() writes does not depend on the order the boxes
        // were ticked in.
        m_selected.append( id );
        QStringList ordered = allIds();
        for ( int i = ordered.count() - 1; i >= 0; --i )
        {
            if ( !m_selected.contains( ordered.at( i ) ) )
            {
                ordered.removeAt( i );
            }
        }
        m_selected = ordered;
    }
    else
    {
        m_selected.removeAt( at );
    }
    emit selectedIdsChanged();
}

void
AppsConfig::recheckInternet()
{
    // The same Manager the greeting page's checker uses, and the same static check URL: greeting
    // registered it from its own internetCheckUrl at startup, so this call needs no configuration
    // of its own and cannot disagree with the check whose verdict sits on the page before this
    // one. The dependency is stated, not hidden — a settings.conf without `greeting` in the
    // sequence would leave Manager unconfigured and this answering a generic-heuristics guess.
    Calamares::Network::Manager nam;
    const bool online = nam.checkHasInternet();

    if ( online == m_hasInternet )
    {
        return;
    }
    m_hasInternet = online;
    emit hasInternetChanged();

    if ( !online )
    {
        // FORCED, and remembered. The mode the user had is restored if the connection returns
        // while they are still here, because a forced answer is not their answer and silently
        // keeping it after the reason for it went away is the one way this page can lie.
        if ( m_mode != QLatin1String( "none" ) )
        {
            m_modeBeforeForce = m_mode;
            m_mode = QStringLiteral( "none" );
            emit modeChanged();
        }
        cDebug() << "apps: no internet; the choice is forced to nothing-extra"
                 << ( m_modeBeforeForce.isEmpty() ? QString() : QStringLiteral( " (was %1)" ).arg( m_modeBeforeForce ) );
    }
    else if ( !m_modeBeforeForce.isEmpty() )
    {
        setMode( m_modeBeforeForce );
        m_modeBeforeForce.clear();
        cDebug() << "apps: internet returned; restoring the choice made before it was forced";
    }
}

QString
AppsConfig::prettyStatus() const
{
    if ( m_mode == QLatin1String( "typical" ) )
    {
        return tr( "Typical application set" );
    }
    if ( m_mode == QLatin1String( "custom" ) )
    {
        QStringList names;
        const QStringList ids = allIds();
        for ( const QString& id : m_selected )
        {
            const int at = ids.indexOf( id );
            names.append( at >= 0
                              ? m_apps.at( at ).toMap().value( QStringLiteral( "name" ) ).toString()
                              : id );
        }
        return names.isEmpty() ? tr( "No extra applications" )
                               : tr( "Extra applications: %1" ).arg( names.join( QStringLiteral( ", " ) ) );
    }
    return tr( "No extra applications" );
}

QStringList
AppsConfig::allIds() const
{
    QStringList out;
    for ( const QVariant& v : m_apps )
    {
        out.append( v.toMap().value( QStringLiteral( "id" ) ).toString() );
    }
    return out;
}

void
AppsConfig::publish( Calamares::GlobalStorage* gs ) const
{
    if ( !gs )
    {
        return;
    }
    // The whole contract with `appsetup`, and it is deliberately two keys. The job installs what
    // appsSelected lists and asks nothing about modes — "typical" is resolved to its ids here,
    // where the list they come from lives, so the job cannot disagree with the page about what
    // the set was. An offline install publishes mode "none" and an empty list; the job still
    // re-checks the network before doing anything at all.
    QString mode = m_mode;
    QStringList refs = m_selected;
    if ( mode == QLatin1String( "typical" ) )
    {
        refs = allIds();
    }
    else if ( mode != QLatin1String( "custom" ) )
    {
        refs.clear();
    }
    else
    {
        // Custom: keep file order and drop anything not configured — the intersection, taken
        // here rather than in the job because the conf's list is what it is intersected with.
        QStringList ordered;
        for ( const QString& id : allIds() )
        {
            if ( refs.contains( id ) )
            {
                ordered.append( id );
            }
        }
        refs = ordered;
    }
    if ( !m_hasInternet )
    {
        mode = QStringLiteral( "none" );
        refs.clear();
    }
    gs->insert( QStringLiteral( "appsMode" ), mode );
    gs->insert( QStringLiteral( "appsSelected" ), refs );
}

void
AppsConfig::retranslate()
{
    emit retranslated();
}

#include "moc_AppsConfig.cpp"
