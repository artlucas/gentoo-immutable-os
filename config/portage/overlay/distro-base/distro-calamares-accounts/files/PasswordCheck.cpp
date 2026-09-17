/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "PasswordCheck.h"

#include <QCoreApplication>

#include <pwquality.h>

// QCoreApplication::translate with THIS file's name as the context, rather than the QObject::tr
// this replaced: a bare utility class is not a QObject and has no tr() of its own, and the
// QObject context could never be finished — check-translations.py check 5 demands that a
// finished context's strings live in the file whose stem is the context name, and nothing is
// named QObject.cpp. The explicit context lands these two strings in PasswordCheck, which is
// this file (plan/27 §1).
void
PasswordCheck::configure( const QStringList& options, int minLength )
{
    m_options = options;
    m_minLength = minLength;
}

PasswordCheck::Result
PasswordCheck::check( const QString& password ) const
{
    Result r;
    if ( password.isEmpty() )
    {
        return r;
    }
    if ( m_minLength > 0 && password.length() < m_minLength )
    {
        r.message = QCoreApplication::translate( "PasswordCheck",
                                                 "The password must be at least %1 characters "
                                                 "long." )
                        .arg( m_minLength );
        return r;
    }

    pwquality_settings_t* pwq = pwquality_default_settings();
    if ( !pwq )
    {
        // Out of memory, and nothing useful to say about it. Fall back to the length rule alone
        // rather than blocking a person out of their own install.
        r.acceptable = true;
        r.score = 50;
        return r;
    }

    for ( const QString& option : m_options )
    {
        // pwquality_set_option takes "key=value" verbatim, which is why accounts.conf carries
        // these as pwquality.conf strings instead of as structured keys: there is nothing to
        // translate, and a new libpwquality option needs no code here.
        pwquality_set_option( pwq, option.toUtf8().constData() );
    }

    void* auxerror = nullptr;
    const int rv = pwquality_check( pwq, password.toUtf8().constData(), nullptr, nullptr, &auxerror );
    if ( rv < 0 )
    {
        char buf[ PWQ_MAX_ERROR_MESSAGE_LEN ] = { 0 };
        const char* msg = pwquality_strerror( buf, sizeof( buf ), rv, auxerror );
        r.message = msg ? QString::fromUtf8( msg )
                        : QCoreApplication::translate( "PasswordCheck",
                                                       "That password is not strong enough." );
    }
    else
    {
        r.acceptable = true;
        r.score = rv;
    }
    pwquality_free_settings( pwq );
    return r;
}
