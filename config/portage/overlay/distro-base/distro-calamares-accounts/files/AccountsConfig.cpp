/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "AccountsConfig.h"

#include "GlobalStorage.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMap>
#include <QProcess>
#include <QRegularExpression>
#include <QTimer>

#ifndef DISTRO_ID
#error DISTRO_ID must be defined (-DDISTRO_ID=...)
#endif

namespace
{

// The same bound managedenroll used, and for the same reason: this runs in front of a person who
// is watching it, and a control plane that accepts the connection and then says nothing is
// exactly the failure being guarded against. The client has its own 30-second HTTP timeout; this
// is the outer bound around enrol-plus-first-sync.
constexpr int ENROL_TIMEOUT_MS = 120 * 1000;
// `verify` does DNS, one LDAP ping and a clock comparison. It is allowed to be slow, not patient.
constexpr int VERIFY_TIMEOUT_MS = 45 * 1000;

QString
distroId()
{
    return QString::fromUtf8( DISTRO_ID );
}

/*! POSIX-portable-ish user name rules, matching what shadow's own useradd accepts: start with a
 *  lower-case letter or underscore, then lower-case letters, digits, underscore or hyphen. Stock
 *  Calamares uses the same shape (USERNAME_RX in users/Config.cpp). */
bool
looksLikeLoginName( const QString& name )
{
    static const QRegularExpression rx( QStringLiteral( "^[a-z_][a-z0-9_-]*$" ) );
    return rx.match( name ).hasMatch();
}

/*! RFC 1123 label rules, which is what hostnamectl and /etc/hosts both want. */
bool
looksLikeHostname( const QString& name )
{
    static const QRegularExpression rx(
        QStringLiteral( "^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$" ) );
    return rx.match( name ).hasMatch();
}

/*! A domain needs at least one dot: `realm`/`adcli` resolve SRV records under it, and a
 *  single-label name is a NetBIOS name, which this path cannot use. */
bool
looksLikeDomain( const QString& name )
{
    static const QRegularExpression rx(
        QStringLiteral( "^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-"
                        "Z0-9])?)+$" ) );
    return rx.match( name ).hasMatch();
}

/*! Stock users derives a login name from the full name, and the page is much better for it.
 *  Same transliteration-free approach: keep what is already a legal character, drop the rest. */
QString
guessLoginName( const QString& fullName )
{
    const QStringList parts = fullName.simplified().toLower().split( QLatin1Char( ' ' ),
                                                                     Qt::SkipEmptyParts );
    if ( parts.isEmpty() )
    {
        return QString();
    }
    QString guess;
    for ( const QChar c : parts.first() )
    {
        if ( c.isLetterOrNumber() && c.unicode() < 128 )
        {
            guess.append( c );
        }
    }
    if ( !guess.isEmpty() && !guess.at( 0 ).isLetter() )
    {
        guess.prepend( QLatin1Char( '_' ) );
    }
    return guess;
}

}  // namespace

AccountsConfig::AccountsConfig( QObject* parent )
    : QObject( parent )
    , m_modesOffered( { QStringLiteral( "local" ),
                        QStringLiteral( "managed" ),
                        QStringLiteral( "domain" ) } )
    , m_shell( QStringLiteral( "/bin/bash" ) )
    , m_homePermissions( QStringLiteral( "o700" ) )
    , m_hostnameTemplate( distroId() )
    , m_failsafeUserName( QStringLiteral( "admin" ) )
    , m_scratchRoot( QStringLiteral( "/run/%1-accounts/enroll" ).arg( distroId() ) )
    , m_secretsPath( QStringLiteral( "/run/%1-accounts/secrets.json" ).arg( distroId() ) )
{
    m_hostname = m_hostnameTemplate;
    m_timeout = new QTimer( this );
    m_timeout->setSingleShot( true );
    connect( m_timeout, &QTimer::timeout, this, [ this ] {
        if ( m_proc && m_proc->state() != QProcess::NotRunning )
        {
            m_proc->kill();
        }
    } );
    revalidate();
}

AccountsConfig::~AccountsConfig()
{
    // The secrets file lives on the live medium's tmpfs and the job unlinks it. If we are being
    // destroyed before the job ran — a cancelled install — nobody else will, so do it here.
    QFile::remove( m_secretsPath );
}

void
AccountsConfig::setConfigurationMap( const QVariantMap& map )
{
    if ( map.contains( QStringLiteral( "modes" ) ) )
    {
        m_modesOffered.clear();
        const QVariantList modes = map.value( QStringLiteral( "modes" ) ).toList();
        for ( const QVariant& m : modes )
        {
            m_modesOffered.append( m.toString().trimmed().toLower() );
        }
        if ( m_modesOffered.isEmpty() )
        {
            // A page offering nothing is a page that cannot be left. Fall back to the one mode
            // that needs no other machinery rather than trapping the installer.
            m_modesOffered.append( QStringLiteral( "local" ) );
        }
    }

    const QVariantList groups = map.value( QStringLiteral( "defaultGroups" ) ).toList();
    for ( const QVariant& g : groups )
    {
        // Two spellings, because users.conf supported both: a bare string, or a map with
        // name/must_exist/system. Only the name matters here — must_exist is the job's business,
        // and it is the job that can actually look in the target.
        if ( g.typeId() == QMetaType::QVariantMap )
        {
            m_defaultGroups.append( g.toMap().value( QStringLiteral( "name" ) ).toString() );
        }
        else
        {
            m_defaultGroups.append( g.toString() );
        }
    }
    m_defaultGroups.removeAll( QString() );

    const QVariantMap user = map.value( QStringLiteral( "user" ) ).toMap();
    if ( user.contains( QStringLiteral( "shell" ) ) )
    {
        m_shell = user.value( QStringLiteral( "shell" ) ).toString();
    }
    if ( user.contains( QStringLiteral( "home_permissions" ) ) )
    {
        m_homePermissions = user.value( QStringLiteral( "home_permissions" ) ).toString();
    }
    for ( const QVariant& n : user.value( QStringLiteral( "forbidden_names" ) ).toList() )
    {
        m_forbiddenLoginNames.append( n.toString() );
    }

    const QVariantMap host = map.value( QStringLiteral( "hostname" ) ).toMap();
    if ( host.contains( QStringLiteral( "template" ) ) )
    {
        m_hostnameTemplate = host.value( QStringLiteral( "template" ) ).toString();
        if ( !m_hostnameEdited )
        {
            m_hostname = m_hostnameTemplate;
            emit hostnameChanged();
        }
    }
    for ( const QVariant& n : host.value( QStringLiteral( "forbidden_names" ) ).toList() )
    {
        m_forbiddenHostnames.append( n.toString() );
    }

    const QVariantMap pw = map.value( QStringLiteral( "passwordRequirements" ) ).toMap();
    m_minPasswordLength = pw.value( QStringLiteral( "minLength" ), 0 ).toInt();
    for ( const QVariant& o : pw.value( QStringLiteral( "libpwquality" ) ).toList() )
    {
        m_pwqualityOptions.append( o.toString() );
    }
    m_pwcheck.configure( m_pwqualityOptions, m_minPasswordLength );

    m_organisationHint = map.value( QStringLiteral( "organisationHint" ) ).toString();
    if ( map.contains( QStringLiteral( "failsafeUserName" ) ) )
    {
        m_failsafeUserName = map.value( QStringLiteral( "failsafeUserName" ) ).toString();
    }
    if ( map.contains( QStringLiteral( "enrolScratchRoot" ) ) )
    {
        m_scratchRoot = map.value( QStringLiteral( "enrolScratchRoot" ) ).toString();
    }
    if ( map.contains( QStringLiteral( "secretsPath" ) ) )
    {
        m_secretsPath = map.value( QStringLiteral( "secretsPath" ) ).toString();
    }
    m_apiBase = map.value( QStringLiteral( "apiBase" ) ).toString();

    revalidate();
}

QString
AccountsConfig::distroTool( const char* suffix ) const
{
    return QStringLiteral( "/usr/bin/%1-%2" ).arg( distroId(), QString::fromUtf8( suffix ) );
}

// ---- the choice -------------------------------------------------------------------------------

void
AccountsConfig::setStep( Step step )
{
    if ( m_step == step )
    {
        return;
    }
    m_step = step;
    emit stepChanged();
    // Next means something different on each screen — "a mode is picked" on the first, "the
    // fields are good" on the second — so the window's button has to be re-asked. ViewManager
    // does ask after its own back()/next(), but not after a step change that starts here (see
    // setMode below), and a stale enabled Next is a click that skips the form.
    refreshNextEnabled();
}

void
AccountsConfig::goToChooser()
{
    setStep( ChooseMode );
}

void
AccountsConfig::goToFields()
{
    // Defensive rather than reachable: Next is disabled on the chooser until a mode is picked,
    // so Calamares does not call this with NoMode. If some other path ever does, showing an
    // empty second screen would be worse than staying put.
    if ( modeChosen() )
    {
        setStep( FillFields );
    }
}

void
AccountsConfig::setMode( Mode mode )
{
    if ( m_mode == mode )
    {
        return;
    }
    // Leaving managed mode with a live enrolment behind it releases the device. Doing this on the
    // way OUT rather than on the way in is what keeps a person who clicks through all three radio
    // buttons from leaving three device records in their organisation.
    if ( m_mode == Managed && m_enrolState == Succeeded )
    {
        releaseEnrolment();
    }
    m_mode = mode;
    // The failsafe administrator is only a default, and only where it is the failsafe. Typing a
    // name in local mode and then switching to domain keeps the name.
    if ( mode == Domain && !m_loginNameEdited && m_loginName.isEmpty() )
    {
        m_loginName = m_failsafeUserName;
        emit loginNameChanged();
    }
    emit modeChanged();
    // Changing the mode while the fields are showing — only reachable from a page that draws the
    // chooser somewhere other than the first screen — would leave the form disagreeing with the
    // choice above it. Sending the page back to the chooser makes that impossible to build by
    // accident.
    if ( m_step == FillFields )
    {
        setStep( ChooseMode );
    }
    revalidate();
}

// ---- the local account ------------------------------------------------------------------------

void
AccountsConfig::setFullName( const QString& name )
{
    if ( m_fullName == name )
    {
        return;
    }
    m_fullName = name;
    emit fullNameChanged();
    if ( !m_loginNameEdited )
    {
        const QString guess = guessLoginName( name );
        if ( guess != m_loginName )
        {
            m_loginName = guess;
            emit loginNameChanged();
        }
    }
    revalidate();
}

void
AccountsConfig::setLoginName( const QString& name )
{
    m_loginNameEdited = true;
    if ( m_loginName == name )
    {
        return;
    }
    m_loginName = name;
    emit loginNameChanged();
    revalidate();
}

void
AccountsConfig::setPassword( const QString& password )
{
    if ( m_password == password )
    {
        return;
    }
    m_password = password;
    emit passwordChanged();
    revalidate();
}

void
AccountsConfig::setPasswordRepeat( const QString& password )
{
    if ( m_passwordRepeat == password )
    {
        return;
    }
    m_passwordRepeat = password;
    emit passwordRepeatChanged();
    revalidate();
}

bool
AccountsConfig::passwordsMatch() const
{
    return !m_password.isEmpty() && m_password == m_passwordRepeat;
}

// ---- the computer's name ----------------------------------------------------------------------

void
AccountsConfig::setHostname( const QString& hostname )
{
    m_hostnameEdited = true;
    if ( m_hostname == hostname )
    {
        return;
    }
    m_hostname = hostname;
    emit hostnameChanged();
    revalidate();
}

// ---- managed mode -----------------------------------------------------------------------------

void
AccountsConfig::setEnrolmentCode( const QString& code )
{
    // Typed by a human off a phone screen, so it is short and case-insensitive (plan/19 §5.2).
    // Upper-casing here saves an error the control plane would otherwise have to explain.
    const QString upper = code.toUpper();
    if ( m_enrolmentCode == upper )
    {
        return;
    }
    // Editing an accepted code abandons the device it produced. The alternative — keeping the
    // first enrolment and ignoring the new text — is a page that lies about what it will do.
    if ( m_enrolState == Succeeded )
    {
        releaseEnrolment();
    }
    m_enrolmentCode = upper;
    emit enrolmentCodeChanged();
    if ( m_enrolState == Failed )
    {
        setEnrol( Idle, QString() );
    }
    revalidate();
}

void
AccountsConfig::setEnrol( ActionState state, const QString& message )
{
    m_enrolState = state;
    m_enrolMessage = message;
    emit enrolStateChanged();
    revalidate();
}

bool
AccountsConfig::seedScratchRoot()
{
    QDir().mkpath( m_scratchRoot + QStringLiteral( "/etc" ) );
    if ( !QFileInfo::exists( m_scratchRoot + QStringLiteral( "/etc" ) ) )
    {
        return false;
    }
    // EMPTY, on purpose. `enroll` refuses a root with no machine-id at all, and an empty one
    // hashes to the same empty hw_fingerprint the installer path has always sent — the machine-id
    // that will identify this machine does not exist until its first boot (plan/21 §3).
    QFile mid( m_scratchRoot + QStringLiteral( "/etc/machine-id" ) );
    if ( !mid.exists() && !mid.open( QIODevice::WriteOnly ) )
    {
        return false;
    }
    mid.close();

    QFile hn( m_scratchRoot + QStringLiteral( "/etc/hostname" ) );
    if ( !hn.open( QIODevice::WriteOnly | QIODevice::Truncate ) )
    {
        return false;
    }
    hn.write( ( m_hostname + QStringLiteral( "\n" ) ).toUtf8() );
    hn.close();
    return true;
}

void
AccountsConfig::checkAndEnrol()
{
    if ( m_enrolState == Running || m_proc )
    {
        return;
    }
    if ( m_enrolmentCode.trimmed().isEmpty() )
    {
        setEnrol( Failed, tr( "Enter the enrolment code from your organisation." ) );
        return;
    }
    if ( !hostnameValid() )
    {
        setEnrol( Failed, tr( "Give this computer a name first." ) );
        return;
    }
    if ( !seedScratchRoot() )
    {
        setEnrol( Failed,
                  tr( "Could not prepare %1. The installer is not running as root." )
                      .arg( m_scratchRoot ) );
        return;
    }

    m_organisationName.clear();
    m_grantedUsers.clear();
    setEnrol( Running, tr( "Contacting your organisation…" ) );

    QStringList args { QStringLiteral( "enroll" ),
                       QStringLiteral( "--code" ),
                       m_enrolmentCode.trimmed(),
                       QStringLiteral( "--name" ),
                       m_hostname,
                       QStringLiteral( "--root" ),
                       m_scratchRoot };
    if ( !m_apiBase.isEmpty() )
    {
        args << QStringLiteral( "--api" ) << m_apiBase;
    }

    m_proc = new QProcess( this );
    m_proc->setProcessChannelMode( QProcess::MergedChannels );
    connect( m_proc,
             &QProcess::finished,
             this,
             [ this ]( int exitCode, QProcess::ExitStatus status ) {
                 m_timeout->stop();
                 const QString output
                     = QString::fromUtf8( m_proc->readAll() ).trimmed();
                 m_proc->deleteLater();
                 m_proc = nullptr;

                 if ( status != QProcess::NormalExit )
                 {
                     setEnrol( Failed,
                               tr( "Your organisation did not answer within two minutes. Check "
                                   "the network and try again." ) );
                     return;
                 }
                 if ( exitCode != 0 )
                 {
                     // The client's own last line: "could not reach …", "that enrolment code has
                     // already been used", "…has expired; ask for a new one". It says it better
                     // than a translation of an exit code would.
                     const QStringList lines = output.split( QLatin1Char( '\n' ),
                                                             Qt::SkipEmptyParts );
                     setEnrol( Failed,
                               lines.isEmpty()
                                   ? tr( "This computer could not be enrolled." )
                                   : lines.last().trimmed() );
                     return;
                 }
                 readEnrolmentResult();
             } );
    m_timeout->start( ENROL_TIMEOUT_MS );
    m_proc->start( distroTool( "managed" ), args );
}

void
AccountsConfig::readEnrolmentResult()
{
    // `status --json` is the client's own account of what happened, offline, and `users` in it is
    // derived from owned.json — the records actually written. Asking the client rather than
    // parsing enroll's prose means this page cannot disagree with `<id>-managed status` on the
    // installed machine.
    QProcess status;
    status.start( distroTool( "managed" ),
                  { QStringLiteral( "status" ),
                    QStringLiteral( "--json" ),
                    QStringLiteral( "--root" ),
                    m_scratchRoot } );
    if ( !status.waitForFinished( 15000 ) )
    {
        status.kill();
        setEnrol( Failed, tr( "The enrolment finished but could not be read back." ) );
        return;
    }
    const QJsonDocument doc = QJsonDocument::fromJson( status.readAllStandardOutput() );
    const QJsonObject info = doc.object();
    if ( !info.value( QStringLiteral( "enrolled" ) ).toBool() )
    {
        setEnrol( Failed, tr( "The enrolment reported success but wrote nothing." ) );
        return;
    }
    m_organisationName = info.value( QStringLiteral( "org" ) ).toString();
    m_grantedUsers.clear();
    for ( const QJsonValue u : info.value( QStringLiteral( "users" ) ).toArray() )
    {
        m_grantedUsers.append( u.toString() );
    }

    if ( m_grantedUsers.isEmpty() )
    {
        // ENROLLED AND STILL UNUSABLE. This mode creates no local account, so a bundle that
        // grants nobody access to this device produces a machine with nothing to log into — the
        // same outcome as a failed enrolment, from a state the web side considers perfectly
        // normal for a machine nobody has been assigned to yet. The enrolment is kept: it is
        // valid, and the fix is one click in the web interface followed by this button again.
        setEnrol( Failed,
                  m_organisationName.isEmpty()
                      ? tr( "This computer is enrolled, but nobody has been given access to it "
                            "yet. Add someone in your organisation's web interface, then try "
                            "again." )
                      : tr( "This computer is enrolled with %1, but nobody has been given access "
                            "to it yet. Add someone in your organisation's web interface, then "
                            "try again." )
                            .arg( m_organisationName ) );
        return;
    }

    setEnrol( Succeeded,
              m_organisationName.isEmpty()
                  ? tr( "Enrolled. %n person can use this computer.", "", int( m_grantedUsers.size() ) )
                  : tr( "Enrolled with %1. %n person can use this computer.",
                        "",
                        int( m_grantedUsers.size() ) )
                        .arg( m_organisationName ) );
}

void
AccountsConfig::releaseEnrolment()
{
    if ( m_enrolState != Succeeded )
    {
        return;
    }
    // Synchronous and short: this runs from a property setter or from onLeave() on the way Back,
    // and there is no UI state left to report it into. --force so it does not prompt, --purge so
    // the scratch tree goes with it.
    QProcess leave;
    leave.start( distroTool( "managed" ),
                 { QStringLiteral( "leave" ),
                   QStringLiteral( "--purge" ),
                   QStringLiteral( "--force" ),
                   QStringLiteral( "--root" ),
                   m_scratchRoot } );
    leave.waitForFinished( 30000 );
    m_organisationName.clear();
    m_grantedUsers.clear();
    setEnrol( Idle, QString() );
}

// ---- domain mode ------------------------------------------------------------------------------

void
AccountsConfig::setDomainName( const QString& domain )
{
    if ( m_domainName == domain.toLower() )
    {
        return;
    }
    m_domainName = domain.toLower();
    setVerify( Idle, QString() );
    emit domainChanged();
    revalidate();
}

void
AccountsConfig::setJoinUser( const QString& user )
{
    if ( m_joinUser == user )
    {
        return;
    }
    m_joinUser = user;
    setVerify( Idle, QString() );
    emit domainChanged();
    revalidate();
}

void
AccountsConfig::setJoinPassword( const QString& password )
{
    if ( m_joinPassword == password )
    {
        return;
    }
    m_joinPassword = password;
    setVerify( Idle, QString() );
    emit domainChanged();
    revalidate();
}

void
AccountsConfig::setDcAddress( const QString& address )
{
    if ( m_dcAddress == address )
    {
        return;
    }
    m_dcAddress = address;
    emit domainChanged();
    revalidate();
}

void
AccountsConfig::setComputerOu( const QString& ou )
{
    if ( m_computerOu == ou )
    {
        return;
    }
    m_computerOu = ou;
    emit domainChanged();
}

void
AccountsConfig::setAdminGroup( const QString& group )
{
    if ( m_adminGroup == group )
    {
        return;
    }
    m_adminGroup = group;
    emit domainChanged();
}

void
AccountsConfig::setComputerName( const QString& name )
{
    if ( m_computerName == name )
    {
        return;
    }
    m_computerName = name;
    emit domainChanged();
}

void
AccountsConfig::setVerify( ActionState state, const QString& message )
{
    if ( m_verifyState == state && m_verifyMessage == message )
    {
        return;
    }
    m_verifyState = state;
    m_verifyMessage = message;
    emit verifyStateChanged();
}

void
AccountsConfig::verifyDomain()
{
    if ( m_verifyState == Running || m_proc )
    {
        return;
    }
    if ( !looksLikeDomain( m_domainName ) || m_joinUser.trimmed().isEmpty() )
    {
        setVerify( Failed, tr( "Enter the domain and a join account first." ) );
        return;
    }
    setVerify( Running, tr( "Checking %1…" ).arg( m_domainName ) );

    m_proc = new QProcess( this );
    m_proc->setProcessChannelMode( QProcess::MergedChannels );
    connect( m_proc,
             &QProcess::finished,
             this,
             [ this ]( int exitCode, QProcess::ExitStatus status ) {
                 m_timeout->stop();
                 m_proc->readAll();
                 m_proc->deleteLater();
                 m_proc = nullptr;
                 if ( status != QProcess::NormalExit )
                 {
                     setVerify( Failed, tr( "The check did not finish in time." ) );
                     return;
                 }
                 // `verify`'s exit codes ARE its interface (plan/18 §4): 2 unreachable,
                 // 3 credentials rejected, 4 clock skew. The same mapping the job uses, so a
                 // person sees the same words here and in `<id>-domain status` afterwards.
                 switch ( exitCode )
                 {
                 case 0:
                     setVerify( Succeeded,
                                tr( "%1 answered and accepted %2." )
                                    .arg( m_domainName, m_joinUser ) );
                     break;
                 case 2:
                     setVerify( Failed,
                                tr( "%1 could not be reached. The installation will still "
                                    "finish, and this computer can be joined afterwards." )
                                    .arg( m_domainName ) );
                     break;
                 case 3:
                     setVerify( Failed,
                                tr( "The domain controller rejected %1." ).arg( m_joinUser ) );
                     break;
                 case 4:
                     setVerify( Failed,
                                tr( "This computer's clock is too far from the domain "
                                    "controller's for Kerberos." ) );
                     break;
                 default:
                     setVerify( Failed,
                                tr( "The domain could not be checked (status %1)." )
                                    .arg( exitCode ) );
                     break;
                 }
             } );
    m_timeout->start( VERIFY_TIMEOUT_MS );
    m_proc->start( distroTool( "domain" ),
                   { QStringLiteral( "verify" ),
                     QStringLiteral( "--domain" ),
                     m_domainName,
                     QStringLiteral( "--user" ),
                     m_joinUser,
                     QStringLiteral( "--password-stdin" ) } );
    if ( m_proc->waitForStarted( 5000 ) )
    {
        m_proc->write( ( m_joinPassword + QStringLiteral( "\n" ) ).toUtf8() );
        m_proc->closeWriteChannel();
    }
}

// ---- validity ---------------------------------------------------------------------------------

void
AccountsConfig::revalidate()
{
    // The local account, in the two modes that have one.
    // An empty field is not an error, it is a field nobody has filled in yet — so it leaves
    // the message empty and `valid` false, and the QML shows neither a complaint nor a tick.
    m_loginNameMessage.clear();
    m_loginNameValid = false;
    if ( m_loginName.isEmpty() )
    {
    }
    else if ( !looksLikeLoginName( m_loginName ) )
    {
        m_loginNameMessage = tr( "Use lower-case letters, digits, - and _, starting with a "
                                 "letter." );
    }
    else if ( m_forbiddenLoginNames.contains( m_loginName, Qt::CaseInsensitive ) )
    {
        m_loginNameMessage = tr( "%1 is already used by this system." ).arg( m_loginName );
    }
    else
    {
        m_loginNameValid = true;
    }

    const PasswordCheck::Result pw = m_pwcheck.check( m_password );
    m_passwordValid = pw.acceptable;
    m_passwordScore = pw.score;
    m_passwordMessage = pw.message;

    m_hostnameMessage.clear();
    m_hostnameValid = false;
    if ( m_hostname.isEmpty() )
    {
    }
    else if ( !looksLikeHostname( m_hostname ) )
    {
        m_hostnameMessage = tr( "Use letters, digits and -, starting and ending with a letter or "
                                "digit." );
    }
    else if ( m_forbiddenHostnames.contains( m_hostname, Qt::CaseInsensitive ) )
    {
        m_hostnameMessage = tr( "%1 cannot be used as a computer name." ).arg( m_hostname );
    }
    else
    {
        m_hostnameValid = true;
    }

    emit validityChanged();

    refreshNextEnabled();
}

void
AccountsConfig::refreshNextEnabled()
{
    const bool isNext = nextEnabled();
    if ( isNext != m_nextEnabledLast )
    {
        m_nextEnabledLast = isNext;
        emit nextEnabledChanged();
    }
}

bool
AccountsConfig::nextEnabled() const
{
    if ( m_step == ChooseMode )
    {
        // The first screen asks one question and nothing else, so it gates on one thing. In
        // particular it does NOT gate on the hostname: the field that holds it is on the second
        // screen, where it starts out valid but has not been seen yet.
        return modeChosen();
    }
    if ( !m_hostnameValid )
    {
        return false;
    }
    switch ( m_mode )
    {
    case NoMode:
        // The whole point of the page: a mode is a decision, and there is no default that is
        // right for everybody.
        return false;
    case Local:
    case Domain:
        // Field validation only. A domain that cannot be reached does NOT block: the local
        // administrator is created either way, `<id>-domain` verifies before it writes, and the
        // failure is recorded for `<id>-domain status` (plan/18 §7.4).
        if ( !( m_loginNameValid && m_passwordValid && passwordsMatch() ) )
        {
            return false;
        }
        if ( m_mode == Domain )
        {
            return looksLikeDomain( m_domainName ) && !m_joinUser.trimmed().isEmpty()
                && !m_joinPassword.isEmpty();
        }
        return true;
    case Managed:
        // THE EXCEPTION, and the only one on this page: mode Managed creates no local account, so
        // it may not be left until the enrolment has actually happened and the bundle has granted
        // somebody. plan/21 §3.
        return m_enrolState == Succeeded && !m_grantedUsers.isEmpty();
    }
    return false;
}

QString
AccountsConfig::prettyStatus() const
{
    switch ( m_mode )
    {
    case Local:
        return tr( "Local account %1 on %2." ).arg( m_loginName, m_hostname );
    case Managed:
        return m_organisationName.isEmpty()
            ? tr( "%1 will be managed by your organisation." ).arg( m_hostname )
            : tr( "%1 will be managed by %2." ).arg( m_hostname, m_organisationName );
    case Domain:
        return tr( "%1 will join %2, with the local administrator %3." )
            .arg( m_hostname, m_domainName, m_loginName );
    case NoMode:
        break;
    }
    return tr( "No accounts have been set up." );
}

// ---- what the job reads -----------------------------------------------------------------------

void
AccountsConfig::publish( Calamares::GlobalStorage* gs ) const
{
    if ( !gs )
    {
        return;
    }

    static const QMap< Mode, QString > names {
        { NoMode, QStringLiteral( "none" ) },
        { Local, QStringLiteral( "local" ) },
        { Managed, QStringLiteral( "managed" ) },
        { Domain, QStringLiteral( "domain" ) },
    };
    gs->insert( QStringLiteral( "accountsMode" ), names.value( m_mode ) );

    // `hostname` keeps its stock name because it has consumers that predate this module:
    // imagedeploy writes /etc/hostname from it as soon as the /etc overlay is mounted, and
    // imageidentity uses its presence to decide whether to stamp out the first-boot hostname unit.
    gs->insert( QStringLiteral( "hostname" ), m_hostname );

    const bool hasLocalUser = ( m_mode == Local || m_mode == Domain );
    // `username` likewise: imageidentity allocates the subuid/subgid range rootless podman needs
    // from it (plan/13). Absent in managed mode, where the managed client owns those ranges.
    gs->insert( QStringLiteral( "username" ), hasLocalUser ? m_loginName : QString() );
    gs->insert( QStringLiteral( "userFullName" ), hasLocalUser ? m_fullName : QString() );
    gs->insert( QStringLiteral( "userGroups" ), hasLocalUser ? m_defaultGroups : QStringList() );
    gs->insert( QStringLiteral( "userShell" ), m_shell );
    gs->insert( QStringLiteral( "homePermissions" ), m_homePermissions );

    // NO managedEnrollmentRequested. `managedenroll` had one, because it was a job with no other
    // way to know whether the page it followed had been used. accountsMode above says the same
    // thing and is the discriminator the job actually switches on, so a boolean beside it is a
    // second source of truth for one fact — and the interesting case is the one where they
    // disagree, which nothing here would notice.
    gs->insert( QStringLiteral( "managedEnrollmentScratchRoot" ),
                m_mode == Managed ? m_scratchRoot : QString() );
    gs->insert( QStringLiteral( "managedDeviceName" ), m_mode == Managed ? m_hostname : QString() );
    // Written for the operator, not for the job: nothing reads this back. It is what makes
    // calamares.log say WHICH organisation a machine was enrolled into, which is the first
    // question asked about an install that produced the wrong accounts.
    gs->insert( QStringLiteral( "managedOrgName" ),
                m_mode == Managed ? m_organisationName : QString() );

    gs->insert( QStringLiteral( "domainName" ), m_mode == Domain ? m_domainName : QString() );
    gs->insert( QStringLiteral( "domainJoinUser" ), m_mode == Domain ? m_joinUser : QString() );
    gs->insert( QStringLiteral( "domainDcAddress" ), m_mode == Domain ? m_dcAddress : QString() );
    gs->insert( QStringLiteral( "domainOu" ), m_mode == Domain ? m_computerOu : QString() );
    gs->insert( QStringLiteral( "domainAdminGroup" ),
                m_mode == Domain ? m_adminGroup : QString() );
    gs->insert( QStringLiteral( "domainComputerName" ),
                m_mode == Domain ? m_computerName : QString() );

    // ---- and the two things that are NOT in GlobalStorage -------------------------------------
    // Calamares can dump GlobalStorage to its log, and the page this one replaces put a live
    // enrolment code in it. The passwords go to a 0600 file on the live medium's tmpfs and the
    // job unlinks it; the code goes nowhere at all, because by now it has been spent (plan/21 §4).
    QJsonObject secrets;
    if ( hasLocalUser )
    {
        secrets.insert( QStringLiteral( "userPassword" ), m_password );
    }
    if ( m_mode == Domain )
    {
        secrets.insert( QStringLiteral( "domainJoinPassword" ), m_joinPassword );
    }

    QDir().mkpath( QFileInfo( m_secretsPath ).path() );
    QFile f( m_secretsPath );
    if ( f.open( QIODevice::WriteOnly | QIODevice::Truncate ) )
    {
        // Permissions BEFORE content: a window in which the file exists, is world-readable and
        // holds a password is a window, however short.
        f.setPermissions( QFileDevice::ReadOwner | QFileDevice::WriteOwner );
        f.write( QJsonDocument( secrets ).toJson( QJsonDocument::Compact ) );
        f.close();
        gs->insert( QStringLiteral( "accountsSecretsPath" ), m_secretsPath );
    }
    else
    {
        // The job will find no path and fail loudly rather than silently creating an account with
        // no password.
        gs->insert( QStringLiteral( "accountsSecretsPath" ), QString() );
    }
}

#include "moc_AccountsConfig.cpp"
