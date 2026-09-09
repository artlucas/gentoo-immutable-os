/*
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "ManagedKcm.h"

#include <KPluginFactory>

#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QStandardPaths>

/*
 * DISTRO_ID arrives as a compile definition from the ebuild rather than as a token substituted
 * into this file. The sources here are not templates on purpose: a .cpp with @TOKEN@ in it does
 * not compile, does not lint and does not open in an editor, and the one thing it would buy —
 * the name of a binary — is a string.
 */
#ifndef DISTRO_ID
#define DISTRO_ID "distro"
#endif

namespace
{
QString managedCli()
{
    return QStringLiteral("/usr/bin/") + QStringLiteral(DISTRO_ID) + QStringLiteral("-managed");
}
}

K_PLUGIN_CLASS_WITH_JSON(ManagedKcm, "kcm_managed.json")

ManagedKcm::ManagedKcm(QObject *parent, const KPluginMetaData &metaData)
    : KQuickConfigModule(parent, metaData)
{
    refresh();
}

ManagedKcm::~ManagedKcm() = default;

void ManagedKcm::setBusy(bool busy)
{
    if (m_busy == busy) {
        return;
    }
    m_busy = busy;
    Q_EMIT busyChanged();
}

void ManagedKcm::setLastError(const QString &error)
{
    if (m_lastError == error) {
        return;
    }
    m_lastError = error;
    Q_EMIT lastErrorChanged();
}

void ManagedKcm::refresh()
{
    /*
     * UNPRIVILEGED, and that is a design decision rather than a convenience: plan/19 §8.8 says a
     * person being managed must be able to see exactly what is in force on their own machine
     * without asking anyone. `status` is readable by them, so this needs no pkexec and the page
     * populates with no prompt.
     */
    QProcess p;
    p.start(managedCli(), {QStringLiteral("status"), QStringLiteral("--json")});
    if (!p.waitForFinished(10000)) {
        p.kill();
        setLastError(QStringLiteral("%1 status did not answer").arg(managedCli()));
        return;
    }

    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(p.readAllStandardOutput(), &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) {
        /* An unparseable status is not the same as an unenrolled machine, and showing the second
         * when the first happened is how a support call starts in the wrong place. */
        setLastError(QStringLiteral("could not read the managed status: %1").arg(err.errorString()));
        m_status = {{QStringLiteral("enrolled"), false}};
        Q_EMIT statusChanged();
        return;
    }

    m_status = doc.object().toVariantMap();
    setLastError(QString());
    Q_EMIT statusChanged();
}

void ManagedKcm::runPrivileged(const QStringList &args, const QString &whatFailed)
{
    if (m_busy) {
        return;
    }
    setBusy(true);
    setLastError(QString());

    /*
     * pkexec, not sudo and not a setuid helper. The prompt comes from the desktop's own polkit
     * agent against org.<id>.managed.policy, and a cancelled prompt is exit 126 — reported as a
     * cancellation rather than as a failure, because telling a person their enrolment broke when
     * they simply changed their mind is worse than saying nothing.
     */
    m_proc = new QProcess(this);
    m_proc->setProgram(QStringLiteral("/usr/bin/pkexec"));
    m_proc->setArguments(QStringList{managedCli()} << args);
    m_proc->setProcessChannelMode(QProcess::MergedChannels);

    connect(m_proc, &QProcess::finished, this, [this, whatFailed](int code, QProcess::ExitStatus st) {
        const QString output = QString::fromUtf8(m_proc->readAll()).trimmed();
        m_proc->deleteLater();
        m_proc = nullptr;
        setBusy(false);
        refresh();

        if (st != QProcess::NormalExit) {
            setLastError(whatFailed);
            Q_EMIT operationFinished(false, whatFailed);
            return;
        }
        if (code == 126 || code == 127) {
            /* 126 is "the polkit prompt was dismissed", 127 is "pkexec is missing". Neither is
             * an enrolment failure and neither should read like one. */
            Q_EMIT operationFinished(false, QString());
            return;
        }
        if (code != 0) {
            const QString message = output.isEmpty() ? whatFailed : output;
            setLastError(message);
            Q_EMIT operationFinished(false, message);
            return;
        }
        Q_EMIT operationFinished(true, output);
    });

    m_proc->start();
}

void ManagedKcm::enroll(const QString &code, const QString &name)
{
    QStringList args{QStringLiteral("enroll"), QStringLiteral("--code"), code};
    if (!name.trimmed().isEmpty()) {
        args << QStringLiteral("--name") << name.trimmed();
    }
    runPrivileged(args, QStringLiteral("This computer could not be enrolled."));
}

void ManagedKcm::syncNow()
{
    runPrivileged({QStringLiteral("sync"), QStringLiteral("--now")},
                  QStringLiteral("The settings could not be refreshed."));
}

void ManagedKcm::leave()
{
    /*
     * --force skips the client's own interactive confirmation, because the confirmation has
     * already happened: the page asks, in a dialog that says what leaving does (§8.9's promise,
     * stated where someone can read it), and a second prompt on a terminal nobody is watching
     * would simply hang.
     */
    runPrivileged({QStringLiteral("leave"), QStringLiteral("--force")},
                  QStringLiteral("This computer could not be removed from its organisation."));
}

#include "ManagedKcm.moc"
