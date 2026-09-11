/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * libpwquality, wrapped once, so the strength meter and the rule that gates Next are the same
 * call. Calamares' own users page does this in src/modules/users/CheckPWQuality.cpp, which is
 * internal to that module and not exported by libcalamares — hence a wrapper here rather than a
 * reuse. It is thirty lines; the alternative is two password policies that can disagree.
 */
#pragma once

#include <QString>
#include <QStringList>

class PasswordCheck
{
public:
    struct Result
    {
        bool acceptable = false;
        /*! libpwquality's own 0..100 score, or 0 when it rejected the password outright. */
        int score = 0;
        /*! Empty when acceptable; otherwise libpwquality's reason, or ours for minLength. */
        QString message;
    };

    /*! `options` are the `libpwquality:` lines from accounts.conf, spelled exactly as
     *  pwquality.conf spells them ("minlen=8"). `minLength` is checked here rather than left to
     *  minlen= alone: accounts.conf carries both keys because users.conf did, and a config that
     *  sets only minLength must still be enforced. */
    void configure( const QStringList& options, int minLength );

    Result check( const QString& password ) const;

private:
    QStringList m_options;
    int m_minLength = 0;
};
