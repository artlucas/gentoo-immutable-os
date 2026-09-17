/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The applications page's state (plan/25).
 *
 * ONE OBJECT, THE SAME SHAPE AS THE DISK PAGE'S: the app list is what it is (read once out of
 * modules/apps.conf and CONSTANT after that — the apps are Flathub IDs and proper-noun names,
 * facts about the world rather than about this machine), and this object is the half that can
 * change: which of the three answers is chosen, which apps the custom answer ticks, and whether
 * there is internet.
 *
 * THE OFFLINE RULE LIVES HERE, not in the QML, because it is the one thing on this page that is
 * not a preference. recheckInternet() is called every time the page is entered; when the answer
 * is "no connection" it forces the mode to "none", the QML disables the other two choices, and —
 * because a forced answer is not a user's answer — the mode the user had chosen first is
 * remembered and restored if the connection comes back while they are still standing on the page.
 * The `appsetup` job re-checks the network itself in the exec phase and skips everything offline,
 * so nothing published here can spend minutes downloading on a connection that has since died.
 *
 * SELECTION IS C++'s, for the disk page's reason: two sources of truth for a set of ticked boxes
 * is how a page ends up drawing "custom: Krita" while publishing a list with LibreOffice in it.
 * The QML pushes each tick here and binds its checkboxes back off selectedIds.
 */
#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>

namespace Calamares
{
class GlobalStorage;
}

class AppsConfig : public QObject
{
    Q_OBJECT

public:
    /*! The three answers: "typical" (the whole list), "none" (nothing extra), "custom" (the
     *  ticked subset). `mode` is the page's one word of state and everything else derives from
     *  it. setMode() refuses anything else — and refuses typical/custom while offline, which is
     *  the enforcement half of the offline rule; the QML's part is disabling the controls so the
     *  refusal is never asked for. */
    Q_PROPERTY( QString mode READ mode WRITE setMode NOTIFY modeChanged )
    /*! The internet verdict, as of the last recheckInternet(). NOT the greeting page's startup
     *  verdict: that one is five minutes old by the time this page is reached and was never
     *  re-asked. Changes whenever the page is entered or "Check again" is pressed. */
    Q_PROPERTY( bool hasInternet READ hasInternet NOTIFY hasInternetChanged )
    /*! [{id, name, icon, description}] out of modules/apps.conf, in file order. The list itself
     *  is read once — the apps are Flathub IDs and proper-noun names, facts about the world
     *  rather than about this machine — but it is NOT CONSTANT: the description is a sentence,
     *  translated at read time through the AppsDescriptions context (the language page's
     *  LanguageNames bargain — the conf text is the lookup key, the .ts entry is hand-maintained
     *  beside it), so the getter re-wraps it and retranslated() is what tells the QML to re-read
     *  (plan/27 §2). Selection lives in selectedIds, so the re-read costs nothing but paint. */
    Q_PROPERTY( QVariantList apps READ apps NOTIFY retranslated )
    /*! The ids currently ticked for the "custom" answer, in file order. Kept in step with the
     *  checkboxes by setSelected(); starting state is all of them, so "custom" begins where
     *  "typical" ends and un-ticking is the only work a user who wants most of the set does. */
    Q_PROPERTY( QVariantList selectedIds READ selectedIds NOTIFY selectedIdsChanged )

    /*! The question at the top, and the sentence under it. Properties rather than qsTr() in the
     *  QML because they carry the product name and the update promise, which are build facts. */
    Q_PROPERTY( QString headline READ headline NOTIFY retranslated )
    Q_PROPERTY( QString subheadline READ subheadline NOTIFY retranslated )
    /*! The offline sentence, shown in place of the choices' enablement rather than as an error:
     *  an offline install is supported and first-class, and this note says what to do later
     *  rather than what went wrong. */
    Q_PROPERTY( QString offlineNote READ offlineNote NOTIFY retranslated )
    /*! "Thunderbird, VLC, LibreOffice, Krita, KRDC, Kate" — the names as configured, joined, for
     *  the typical row's second line. CONSTANT for the same reason as `apps`. */
    Q_PROPERTY( QString typicalNames READ typicalNames CONSTANT )

    /*! EVERY WORD THIS PAGE SHOWS IS A C++ PROPERTY, not a qsTr() in the QML — the one place this
     *  module departs from its four siblings, and not by preference: the builder's lupdate
     *  (dev-qt/qttools 6.11) is built without QML support ("missing qml/javascript support"),
     *  so a qsTr() in a .qml here has never reached the branding catalogue and renders English
     *  in all nine languages. Strings behind NOTIFY retranslated are extracted, translated and
     *  re-said on a language change like any tr() in this installer. */
    Q_PROPERTY( QString checkAgainLabel READ checkAgainLabel NOTIFY retranslated )
    Q_PROPERTY( QString typicalTitle READ typicalTitle NOTIFY retranslated )
    Q_PROPERTY( QString noneTitle READ noneTitle NOTIFY retranslated )
    Q_PROPERTY( QString noneSubtitle READ noneSubtitle NOTIFY retranslated )
    Q_PROPERTY( QString customTitle READ customTitle NOTIFY retranslated )
    Q_PROPERTY( QString customSubtitle READ customSubtitle NOTIFY retranslated )

    explicit AppsConfig( QObject* parent = nullptr );

    void setConfigurationMap( const QVariantMap& configurationMap );

    QString mode() const { return m_mode; }
    void setMode( const QString& mode );
    bool hasInternet() const { return m_hasInternet; }
    QVariantList apps() const;
    QVariantList selectedIds() const;
    QString headline() const;
    QString subheadline() const;
    QString offlineNote() const;
    QString typicalNames() const;
    QString checkAgainLabel() const;
    QString typicalTitle() const;
    QString noneTitle() const;
    QString noneSubtitle() const;
    QString customTitle() const;
    QString customSubtitle() const;

    /*! One checkbox's worth of the custom answer, pushed from the QML. Unknown ids are dropped
     *  without a signal — a stale binding naming an app a newer conf removed must not un-tick
     *  everything else the user chose. */
    Q_INVOKABLE void setSelected( const QString& id, bool selected );

    /*! Ask Calamares' Network::Manager again. Bound to "Check again" and called from the view
     *  step's onActivate(); see the header of AppsViewStep.cpp for why it is both. */
    Q_INVOKABLE void recheckInternet();

    /*! What the summary page shows: the choice, in the words the page offered it in. */
    QString prettyStatus() const;

    /*! Writes the answer into GlobalStorage. `appsetup` reads it; nothing else does.
     *
     *  THE RESOLVED LIST, NOT THE MODE ALONE. typical publishes every id in file order and none
     *  publishes an empty list, so the job never has to know what "typical" meant — one job
     *  works unchanged if the set in apps.conf ever grows, and a custom selection is
     *  pre-intersected with the configured ids here, where the list they came from is at hand. */
    void publish( Calamares::GlobalStorage* gs ) const;

public slots:
    void retranslate();

signals:
    void modeChanged();
    void hasInternetChanged();
    void selectedIdsChanged();
    void retranslated();

private:
    /*! Every configured id, in file order — what "typical" means and what publish() starts from. */
    QStringList allIds() const;

    QVariantList m_apps;
    QStringList m_selected;
    QString m_mode = QStringLiteral( "none" );
    bool m_hasInternet = true;

    /*! The mode chosen before the last offline force, to restore if the connection returns while
     *  the user is still on the page. Empty when no force is in force. */
    QString m_modeBeforeForce;
};
