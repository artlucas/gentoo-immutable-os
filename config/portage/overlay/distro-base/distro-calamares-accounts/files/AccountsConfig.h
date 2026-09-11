/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * All of the accounts page's state, in one QObject (plan/21).
 *
 * This is what the QML binds to and what AccountsViewStep::onLeave() publishes. Keeping it one
 * object rather than one per mode is deliberate: `nextEnabled` is a single answer that depends on
 * which mode is selected, and the three modes share the hostname field. Splitting it would put
 * that dependency in the QML, where it could not be unit-reasoned about and where a fourth mode
 * would have to remember to update it.
 *
 * THE ONE THING TO KNOW BEFORE CHANGING ANYTHING HERE. Modes Local and Domain collect a password
 * and never block on the network, exactly as Calamares' stock users page did. Mode Managed
 * collects a single-use code and DOES block: checkAndEnrol() runs the enrolment for real, into a
 * scratch root on the live medium, and Next stays disabled until it has succeeded. plan/21 §3 is
 * the whole argument; the short version is that managed mode creates no local account, so an
 * install that completes without a successful enrolment is a disk nobody can log into, and the
 * "never block the install" rule every other surface here obeys was written on the assumption
 * that a local account existed anyway.
 */
#pragma once

#include <QObject>
#include <QStringList>
#include <QVariantMap>

#include "PasswordCheck.h"

class QProcess;
class QTimer;

namespace Calamares
{
class GlobalStorage;
}

class AccountsConfig : public QObject
{
    Q_OBJECT

public:
    enum Mode
    {
        NoMode = 0,
        Local,
        Managed,
        Domain,
    };
    Q_ENUM( Mode )

    /*! Which of the page's two screens is showing. This is not a QML detail: Calamares drives it
     *  through ViewStep::isAtBeginning()/back() and isAtEnd()/next(), so the window's own Back and
     *  Next buttons move between the screens, and a Back pressed on ChooseMode leaves the module
     *  for the partition page the way it always did (ViewManager.cpp:back/next). Keeping the index
     *  here rather than in the QML is what lets AccountsViewStep answer those four questions.
     */
    enum Step
    {
        ChooseMode = 0,
        FillFields,
    };
    Q_ENUM( Step )

    /*! The state of the one asynchronous action on this page. */
    enum ActionState
    {
        Idle = 0,
        Running,
        Succeeded,
        Failed,
    };
    Q_ENUM( ActionState )

    // ---- which screen ------------------------------------------------------------------------
    Q_PROPERTY( Step step READ step NOTIFY stepChanged )
    /*! As booleans, for the same reason the modes are: a context property cannot spell
     *  `AccountsConfig.FillFields`, and `accounts.step === 1` is a binding that renumbering
     *  breaks in silence. */
    Q_PROPERTY( bool onChooser READ onChooser NOTIFY stepChanged )
    Q_PROPERTY( bool onFields READ onFields NOTIFY stepChanged )

    // ---- the choice --------------------------------------------------------------------------
    Q_PROPERTY( Mode mode READ mode WRITE setMode NOTIFY modeChanged )
    /*! The mode, as booleans. AccountsConfig is a context property rather than a registered QML
     *  type, so QML cannot spell `AccountsConfig.Managed` — and a page whose `visible` bindings
     *  read `accounts.mode === 2` is a page where renumbering the enum breaks the UI silently.
     *  These are what the QML binds to; `mode` itself is only ever WRITTEN, from one place. */
    Q_PROPERTY( bool modeChosen READ modeChosen NOTIFY modeChanged )
    Q_PROPERTY( bool isLocalMode READ isLocalMode NOTIFY modeChanged )
    Q_PROPERTY( bool isManagedMode READ isManagedMode NOTIFY modeChanged )
    Q_PROPERTY( bool isDomainMode READ isDomainMode NOTIFY modeChanged )
    /*! Which modes this build offers, from accounts.conf's `modes:`. The QML draws one radio
     *  button per entry, so a profile that ships neither managed mode nor the domain packages
     *  does not advertise them. */
    Q_PROPERTY( bool localOffered READ localOffered CONSTANT )
    Q_PROPERTY( bool managedOffered READ managedOffered CONSTANT )
    Q_PROPERTY( bool domainOffered READ domainOffered CONSTANT )

    // ---- the local account (modes Local and Domain) -------------------------------------------
    Q_PROPERTY( QString fullName READ fullName WRITE setFullName NOTIFY fullNameChanged )
    Q_PROPERTY( QString loginName READ loginName WRITE setLoginName NOTIFY loginNameChanged )
    Q_PROPERTY( QString password READ password WRITE setPassword NOTIFY passwordChanged )
    Q_PROPERTY( QString passwordRepeat READ passwordRepeat WRITE setPasswordRepeat NOTIFY
                    passwordRepeatChanged )
    Q_PROPERTY( QString loginNameMessage READ loginNameMessage NOTIFY validityChanged )
    Q_PROPERTY( bool loginNameValid READ loginNameValid NOTIFY validityChanged )
    Q_PROPERTY( QString passwordMessage READ passwordMessage NOTIFY validityChanged )
    Q_PROPERTY( bool passwordValid READ passwordValid NOTIFY validityChanged )
    /*! libpwquality's 0..100 score, for the meter. Not a gate — passwordValid is the gate. */
    Q_PROPERTY( int passwordScore READ passwordScore NOTIFY validityChanged )
    Q_PROPERTY( bool passwordsMatch READ passwordsMatch NOTIFY validityChanged )

    // ---- the computer's name (every mode) ----------------------------------------------------
    Q_PROPERTY( QString hostname READ hostname WRITE setHostname NOTIFY hostnameChanged )
    Q_PROPERTY( QString hostnameMessage READ hostnameMessage NOTIFY validityChanged )
    Q_PROPERTY( bool hostnameValid READ hostnameValid NOTIFY validityChanged )

    // ---- managed mode ------------------------------------------------------------------------
    Q_PROPERTY(
        QString enrolmentCode READ enrolmentCode WRITE setEnrolmentCode NOTIFY enrolmentCodeChanged )
    Q_PROPERTY( ActionState enrolState READ enrolState NOTIFY enrolStateChanged )
    Q_PROPERTY( bool enrolRunning READ enrolRunning NOTIFY enrolStateChanged )
    Q_PROPERTY( bool enrolSucceeded READ enrolSucceeded NOTIFY enrolStateChanged )
    Q_PROPERTY( bool enrolFailed READ enrolFailed NOTIFY enrolStateChanged )
    Q_PROPERTY( QString enrolMessage READ enrolMessage NOTIFY enrolStateChanged )
    Q_PROPERTY( QString organisationName READ organisationName NOTIFY enrolStateChanged )
    /*! The names the bundle granted this device. Empty after a successful enrolment is its own
     *  failure — see checkAndEnrol(). */
    Q_PROPERTY( QStringList grantedUsers READ grantedUsers NOTIFY enrolStateChanged )
    /*! From accounts.conf. A shop imaging six machines puts its own name on the page. */
    Q_PROPERTY( QString organisationHint READ organisationHint CONSTANT )

    // ---- domain mode -------------------------------------------------------------------------
    Q_PROPERTY( QString domainName READ domainName WRITE setDomainName NOTIFY domainChanged )
    Q_PROPERTY( QString joinUser READ joinUser WRITE setJoinUser NOTIFY domainChanged )
    Q_PROPERTY( QString joinPassword READ joinPassword WRITE setJoinPassword NOTIFY domainChanged )
    Q_PROPERTY( QString dcAddress READ dcAddress WRITE setDcAddress NOTIFY domainChanged )
    Q_PROPERTY( QString computerOu READ computerOu WRITE setComputerOu NOTIFY domainChanged )
    Q_PROPERTY( QString adminGroup READ adminGroup WRITE setAdminGroup NOTIFY domainChanged )
    Q_PROPERTY(
        QString computerName READ computerName WRITE setComputerName NOTIFY domainChanged )
    Q_PROPERTY( ActionState verifyState READ verifyState NOTIFY verifyStateChanged )
    Q_PROPERTY( bool verifyRunning READ verifyRunning NOTIFY verifyStateChanged )
    Q_PROPERTY( bool verifyOk READ verifyOk NOTIFY verifyStateChanged )
    Q_PROPERTY( bool verifyFailed READ verifyFailed NOTIFY verifyStateChanged )
    Q_PROPERTY( QString verifyMessage READ verifyMessage NOTIFY verifyStateChanged )

    // ---- the answer --------------------------------------------------------------------------
    Q_PROPERTY( bool nextEnabled READ nextEnabled NOTIFY nextEnabledChanged )

    explicit AccountsConfig( QObject* parent = nullptr );
    ~AccountsConfig() override;

    void setConfigurationMap( const QVariantMap& map );

    Step step() const { return m_step; }
    bool onChooser() const { return m_step == ChooseMode; }
    bool onFields() const { return m_step == FillFields; }

    Mode mode() const { return m_mode; }
    bool modeChosen() const { return m_mode != NoMode; }
    bool isLocalMode() const { return m_mode == Local; }
    bool isManagedMode() const { return m_mode == Managed; }
    bool isDomainMode() const { return m_mode == Domain; }
    bool localOffered() const { return m_modesOffered.contains( QStringLiteral( "local" ) ); }
    bool managedOffered() const { return m_modesOffered.contains( QStringLiteral( "managed" ) ); }
    bool domainOffered() const { return m_modesOffered.contains( QStringLiteral( "domain" ) ); }

    QString fullName() const { return m_fullName; }
    QString loginName() const { return m_loginName; }
    QString password() const { return m_password; }
    QString passwordRepeat() const { return m_passwordRepeat; }
    QString hostname() const { return m_hostname; }
    QString enrolmentCode() const { return m_enrolmentCode; }
    QString organisationHint() const { return m_organisationHint; }
    QString domainName() const { return m_domainName; }
    QString joinUser() const { return m_joinUser; }
    QString joinPassword() const { return m_joinPassword; }
    QString dcAddress() const { return m_dcAddress; }
    QString computerOu() const { return m_computerOu; }
    QString adminGroup() const { return m_adminGroup; }
    QString computerName() const { return m_computerName; }

    QString loginNameMessage() const { return m_loginNameMessage; }
    bool loginNameValid() const { return m_loginNameValid; }
    QString passwordMessage() const { return m_passwordMessage; }
    bool passwordValid() const { return m_passwordValid; }
    int passwordScore() const { return m_passwordScore; }
    bool passwordsMatch() const;
    QString hostnameMessage() const { return m_hostnameMessage; }
    bool hostnameValid() const { return m_hostnameValid; }

    ActionState enrolState() const { return m_enrolState; }
    bool enrolRunning() const { return m_enrolState == Running; }
    bool enrolSucceeded() const { return m_enrolState == Succeeded; }
    bool enrolFailed() const { return m_enrolState == Failed; }
    QString enrolMessage() const { return m_enrolMessage; }
    QString organisationName() const { return m_organisationName; }
    QStringList grantedUsers() const { return m_grantedUsers; }
    ActionState verifyState() const { return m_verifyState; }
    bool verifyRunning() const { return m_verifyState == Running; }
    bool verifyOk() const { return m_verifyState == Succeeded; }
    bool verifyFailed() const { return m_verifyState == Failed; }
    QString verifyMessage() const { return m_verifyMessage; }

    bool nextEnabled() const;

    /*! One line for the summary page, in the mode's own terms. */
    QString prettyStatus() const;

    /*! Publish everything the `accountsetup` job needs. Passwords do NOT go here — they go to
     *  the 0600 file named by `accountsSecretsPath`, because Calamares can dump GlobalStorage to
     *  its log and the old managed page put a live enrolment code in it (plan/21 §4). */
    void publish( Calamares::GlobalStorage* gs ) const;

public Q_SLOTS:
    /*! Move between the page's two screens. Called from two places that must agree: the window's
     *  Back and Next buttons, through AccountsViewStep::back()/next() — the only navigation the
     *  page offers — and setMode(), which cannot leave somebody looking at a form for a mode they
     *  are no longer in. */
    void goToChooser();
    void goToFields();

    void setMode( Mode mode );
    void setFullName( const QString& name );
    void setLoginName( const QString& name );
    void setPassword( const QString& password );
    void setPasswordRepeat( const QString& password );
    void setHostname( const QString& hostname );
    void setEnrolmentCode( const QString& code );
    void setDomainName( const QString& domain );
    void setJoinUser( const QString& user );
    void setJoinPassword( const QString& password );
    void setDcAddress( const QString& address );
    void setComputerOu( const QString& ou );
    void setAdminGroup( const QString& group );
    void setComputerName( const QString& name );

    /*! Enrol, for real, into the scratch root — the irreversible step, taken while it is still
     *  free. Sets enrolState to Succeeded only when the enrolment stuck AND the bundle granted
     *  at least one user, because a bundle that grants nobody installs a machine with no
     *  accounts as surely as a failed enrolment would. */
    void checkAndEnrol();

    /*! Tell the control plane this device is not happening after all. Called when the code is
     *  edited or the mode changed after a successful enrolment, and on the way Back. Without it
     *  every abandoned install leaves a device record nothing will ever check in. */
    void releaseEnrolment();

    /*! `<id>-domain verify`, which is advisory only: a domain that cannot be reached does not
     *  block this page, because mode Domain creates a local administrator either way. */
    void verifyDomain();

Q_SIGNALS:
    void stepChanged();
    void modeChanged();
    void fullNameChanged();
    void loginNameChanged();
    void passwordChanged();
    void passwordRepeatChanged();
    void hostnameChanged();
    void enrolmentCodeChanged();
    void domainChanged();
    void validityChanged();
    void enrolStateChanged();
    void verifyStateChanged();
    void nextEnabledChanged();

private:
    void setStep( Step step );
    /*! Emit nextEnabledChanged() if, and only if, the answer moved. */
    void refreshNextEnabled();
    void revalidate();
    void setEnrol( ActionState state, const QString& message );
    void setVerify( ActionState state, const QString& message );
    /*! Seed the scratch root the client insists on: an `etc/`, an EMPTY `etc/machine-id` and an
     *  `etc/hostname`. See plan/21 §3 for why each one is there. */
    bool seedScratchRoot();
    void readEnrolmentResult();
    QString distroTool( const char* suffix ) const;

    Step m_step = ChooseMode;

    Mode m_mode = NoMode;
    QStringList m_modesOffered;

    QString m_fullName;
    QString m_loginName;
    QString m_password;
    QString m_passwordRepeat;
    QString m_hostname;
    QString m_enrolmentCode;

    QString m_domainName;
    QString m_joinUser;
    QString m_joinPassword;
    QString m_dcAddress;
    QString m_computerOu;
    QString m_adminGroup;
    QString m_computerName;

    // Whether the person has typed in these fields themselves. Until they have, editing the full
    // name keeps guessing them, which is stock users' behaviour and the reason its page felt
    // like one field rather than three.
    bool m_loginNameEdited = false;
    bool m_hostnameEdited = false;

    QString m_loginNameMessage;
    bool m_loginNameValid = false;
    QString m_passwordMessage;
    bool m_passwordValid = false;
    int m_passwordScore = 0;
    QString m_hostnameMessage;
    bool m_hostnameValid = false;
    // The last value nextEnabled() reported, so revalidate() can emit its signal only when
    // the answer actually moved. Calamares asks the ViewStep, not this object, so a spurious
    // emission is cheap — but a MISSING one leaves the button wrong, which is why the value
    // is cached here rather than recomputed at the call site.
    bool m_nextEnabledLast = false;

    ActionState m_enrolState = Idle;
    QString m_enrolMessage;
    QString m_organisationName;
    QStringList m_grantedUsers;
    ActionState m_verifyState = Idle;
    QString m_verifyMessage;

    QProcess* m_proc = nullptr;
    QTimer* m_timeout = nullptr;

    // ---- from accounts.conf ------------------------------------------------------------------
    QStringList m_defaultGroups;
    QString m_shell;
    QString m_homePermissions;
    QStringList m_forbiddenLoginNames;
    QStringList m_forbiddenHostnames;
    QString m_hostnameTemplate;
    QStringList m_pwqualityOptions;
    int m_minPasswordLength = 0;
    QString m_organisationHint;
    QString m_failsafeUserName;
    QString m_scratchRoot;
    QString m_secretsPath;
    QString m_apiBase;

    PasswordCheck m_pwcheck;
};
