/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * The System Settings module for managed mode (plan/19 §7.2, Phase D).
 *
 * WHAT THIS BUYS OVER THE QML APP, which is the whole justification for the overlay this is
 * built out of: a C++ backend can run a process. Pure QML cannot — there is no QProcess binding
 * and nothing in Kirigami provides one — so <id>-managed-ui had to be split into a shell
 * controller that runs a view and acts on an exit code. Here the view and the backend are one
 * object, so enrolling is a button that reports its own progress and its own errors, and the
 * page updates in place instead of the window being torn down and relaunched.
 *
 * It also carries a KLocalizedContext, which is what makes i18n() exist in the QML — measured on
 * the built target, the bare qml6 runtime does not, and every string in the standalone app
 * rendered empty until they were unwrapped.
 *
 * NOT setuid, and it never asks to be. Everything that changes the machine goes through
 * `pkexec <id>-managed`, against the actions in org.<id>.managed.policy, so the authentication
 * prompt is polkit's and this process stays unprivileged for its whole life.
 */
#pragma once

#include <KQuickConfigModule>

#include <QJsonObject>
#include <QProcess>
#include <QString>

class ManagedKcm : public KQuickConfigModule
{
    Q_OBJECT

    /*! The parsed output of `<id>-managed status --json`. The CLI is the single authority on
     *  what is in force; re-deriving any of it here would be a second implementation to keep
     *  true, and the one a support call would not be looking at. */
    Q_PROPERTY(QVariantMap status READ status NOTIFY statusChanged)

    /*! True while a privileged operation is running, so the page can disable its buttons rather
     *  than letting a second pkexec prompt stack on the first. */
    Q_PROPERTY(bool busy READ busy NOTIFY busyChanged)

    /*! The last thing that went wrong, in the words the CLI used. Empty when nothing has. */
    Q_PROPERTY(QString lastError READ lastError NOTIFY lastErrorChanged)

public:
    ManagedKcm(QObject *parent, const KPluginMetaData &metaData);
    ~ManagedKcm() override;

    QVariantMap status() const
    {
        return m_status;
    }
    bool busy() const
    {
        return m_busy;
    }
    QString lastError() const
    {
        return m_lastError;
    }

    /*! Re-read the cached state. Deliberately cheap and offline: `status` touches no network,
     *  which is what makes it the right thing to call on every page activation. */
    Q_INVOKABLE void refresh();

    Q_INVOKABLE void enroll(const QString &code, const QString &name);
    Q_INVOKABLE void syncNow();
    Q_INVOKABLE void leave();

Q_SIGNALS:
    void statusChanged();
    void busyChanged();
    void lastErrorChanged();
    /*! Emitted when a privileged operation finishes, so the page can show one sentence about it
     *  rather than the user having to infer success from the fields changing. */
    void operationFinished(bool ok, const QString &message);

private:
    void runPrivileged(const QStringList &args, const QString &whatFailed);
    void setBusy(bool busy);
    void setLastError(const QString &error);

    QVariantMap m_status;
    bool m_busy = false;
    QString m_lastError;
    QProcess *m_proc = nullptr;
};
