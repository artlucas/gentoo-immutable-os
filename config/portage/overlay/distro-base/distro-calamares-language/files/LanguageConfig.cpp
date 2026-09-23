/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "LanguageConfig.h"

#include "Branding.h"
#include "GlobalStorage.h"
#include "JobQueue.h"
#include "locale/Global.h"
#include "locale/Translation.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"
#include "utils/Variant.h"

#include <QCoreApplication>
#include <QLocale>
#include <QVariantList>

// ================================ LanguageModel ==============================================

LanguageModel::LanguageModel( QObject* parent )
    : QAbstractListModel( parent )
{
}

void
LanguageModel::setEntries( const QVector< Entry >& entries )
{
    beginResetModel();
    m_entries = entries;
    endResetModel();
}

int
LanguageModel::rowCount( const QModelIndex& parent ) const
{
    return parent.isValid() ? 0 : static_cast< int >( m_entries.count() );
}

QVariant
LanguageModel::data( const QModelIndex& index, int role ) const
{
    if ( !index.isValid() || index.row() < 0 || index.row() >= m_entries.count() )
    {
        return {};
    }
    const Entry& e = m_entries.at( index.row() );
    switch ( role )
    {
    case LabelRole:
        // NEVER translated. Column 3 is the language's own name in its own language, which is the
        // one string on this page that must read the same whatever the UI language currently is —
        // it is how somebody who cannot read the current language finds their way out.
        return e.label;
    case NameRole:
        // translate(), not tr(): the source string arrives at runtime out of the configuration
        // file, so there is no literal here for lupdate to find. The LanguageNames context is
        // written by hand in config/calamares/branding/installer/lang/*.ts, and stage 40 checks
        // that every row of the table has an entry there (plan/22 §4).
        return QCoreApplication::translate( "LanguageNames", e.english.toUtf8().constData() );
    case IdRole:
        return e.id;
    case LocaleRole:
        return e.locale;
    case LocaleShortRole:
    {
        // section(), not a regex: the shape is always <lang>_<TERRITORY>.<CODESET>, stage 40
        // writes it, and a locale with no dot in it simply keeps all of itself.
        const int dot = e.locale.indexOf( QLatin1Char( '.' ) );
        return dot < 0 ? e.locale : e.locale.left( dot );
    }
    default:
        return {};
    }
}

QHash< int, QByteArray >
LanguageModel::roleNames() const
{
    return { { LabelRole, "label" },
             { NameRole, "name" },
             { IdRole, "languageId" },
             { LocaleRole, "locale" },
             { LocaleShortRole, "localeShort" } };
}

void
LanguageModel::retranslated()
{
    if ( m_entries.isEmpty() )
    {
        return;
    }
    emit dataChanged( index( 0 ), index( static_cast< int >( m_entries.count() ) - 1 ), { NameRole } );
}

int
LanguageModel::indexOfId( const QString& id ) const
{
    for ( int row = 0; row < m_entries.count(); ++row )
    {
        if ( m_entries.at( row ).id == id )
        {
            return row;
        }
    }
    return -1;
}

int
LanguageModel::bestIndexFor( const QString& localeName ) const
{
    // "de_AT.UTF-8" -> try "de_AT", then "de". Deliberately NOT a QLocale comparison: the table's
    // ids are Calamares translation ids and a QLocale round-trip would turn "pt_BR" into a
    // territory match that also accepts pt_PT, which is a different catalogue and a different
    // label on the page.
    const QString bare = localeName.section( QLatin1Char( '.' ), 0, 0 );
    int row = indexOfId( bare );
    if ( row >= 0 )
    {
        return row;
    }
    const QString language = bare.section( QLatin1Char( '_' ), 0, 0 );
    row = indexOfId( language );
    if ( row >= 0 )
    {
        return row;
    }
    // Any row whose id starts with the same language, so a system set to de_CH still lands on de
    // if the table happened to spell it de_DE.
    for ( int i = 0; i < m_entries.count(); ++i )
    {
        if ( m_entries.at( i ).id.section( QLatin1Char( '_' ), 0, 0 ) == language )
        {
            return i;
        }
    }
    return -1;
}

// ================================ LanguageConfig =============================================

LanguageConfig::LanguageConfig( QObject* parent )
    : QObject( parent )
    , m_model( new LanguageModel( this ) )
{
    // The body also runs immediately, which is what the macro is for: setup and translation in
    // one place. Harmless here — the model is empty until setConfigurationMap().
    CALAMARES_RETRANSLATE_SLOT( &LanguageConfig::retranslate );
}

void
LanguageConfig::setConfigurationMap( const QVariantMap& configurationMap )
{
    // `languages:` is rendered into this file by stage 40, out of config/languages.conf. A
    // packaged fallback ships with the module so it is loadable on its own (see the note about
    // INSTALL_CONFIG in CMakeLists.txt), but the medium always gets the rendered one from /etc.
    QVector< LanguageModel::Entry > entries;
    const QVariantList rows = configurationMap.value( QStringLiteral( "languages" ) ).toList();
    for ( const QVariant& row : rows )
    {
        const QVariantMap m = row.toMap();
        LanguageModel::Entry e;
        e.id = Calamares::getString( m, QStringLiteral( "id" ) );
        e.locale = Calamares::getString( m, QStringLiteral( "locale" ) );
        e.label = Calamares::getString( m, QStringLiteral( "label" ) );
        e.english = Calamares::getString( m, QStringLiteral( "english" ) );
        if ( e.id.isEmpty() || e.locale.isEmpty() || e.label.isEmpty() || e.english.isEmpty() )
        {
            cWarning() << "language: skipping an incomplete `languages:` entry" << m;
            continue;
        }
        entries.append( e );
    }

    if ( entries.isEmpty() )
    {
        // A page with no languages is a page with nothing on it, and the sequence's first step
        // being blank is worth a loud line in the log rather than a shrug.
        cError() << "language: `languages:` is empty — the picker will have no rows. stage 40 "
                    "renders it from config/languages.conf; a medium that reached this point has "
                    "a rendering bug, not a configuration choice.";
    }
    m_model->setEntries( entries );

    // The medium boots with no LANG set, so QLocale::system() is the C locale and this resolves to
    // English — which is correct, and is also why English is preselected rather than first in the
    // list. A machine whose firmware or boot entry did set one lands on that instead.
    //
    // THE PAGE USED TO THROW THIS AWAY. Language.qml's ListView assigned its own currentIndex
    // during componentComplete() and pushed that 0 straight back here, so the installer opened in
    // whatever language config/languages.conf lists first — German — no matter what this chose.
    // The `currentIndex: -1` block in the QML is what stops it; this comment is here because the
    // two lines are a pair and only one of them looks like it is about the default language.
    int row = m_model->bestIndexFor( QLocale::system().name() );
    if ( row < 0 )
    {
        row = m_model->indexOfId( QStringLiteral( "en" ) );
    }
    if ( row < 0 )
    {
        row = entries.isEmpty() ? -1 : 0;
    }
    setCurrentIndex( row );
    // setCurrentIndex() is a no-op when the index has not changed, and m_currentIndex starts at
    // -1, so the line above always fires once — which is what installs the first translator and
    // writes the first LANG into GlobalStorage. If it ever stops being a no-op-guarded setter,
    // this needs an unconditional publish().
}

QAbstractItemModel*
LanguageConfig::languagesModel() const
{
    return m_model;
}

void
LanguageConfig::setCurrentIndex( int index )
{
    if ( index < 0 || index >= m_model->rowCount() || index == m_currentIndex )
    {
        return;
    }
    m_currentIndex = index;

    const LanguageModel::Entry& e = m_model->entries().at( index );

    // The default QLocale, which is what every number, date and formattedDataSize in this
    // installer then follows — including the "443.2 GiB" on the greeting page's disk row.
    QLocale::setDefault( QLocale( e.locale.section( QLatin1Char( '.' ), 0, 0 ) ) );

    const auto* branding = Calamares::Branding::instance();
    Calamares::installTranslator( Calamares::Locale::Translation::Id { e.id },
                                  branding ? branding->translationsDirectory() : QString() );

    publish();
    emit currentIndexChanged();
    // Not emitted from retranslate(): installTranslator posts QEvent::LanguageChange, so the
    // Retranslator gets there on its own and retranslate() runs then. This signal is only about
    // which row is selected.
}

void
LanguageConfig::publish() const
{
    if ( !Calamares::JobQueue::instance() || !Calamares::JobQueue::instance()->globalStorage() )
    {
        return;
    }
    // THE TRANSLATION ID, NOT THE GLIBC LOCALE, and that is upstream's contract kept on purpose.
    // locale/Config::automaticLocaleConfiguration() reads this key back and runs it through
    // LocaleConfiguration::fromLanguageAndLocation() against the locales the target actually has
    // — which, since locale.conf now names localeGenPath and /usr/share/i18n/SUPPORTED is gone
    // from this medium, is exactly the nine in config/languages.conf (plan/22 §6). Writing the
    // glibc name here instead would bypass that mapping and the timezone half of it with it.
    Calamares::Locale::insertGS( *Calamares::JobQueue::instance()->globalStorage(),
                                 QStringLiteral( "LANG" ),
                                 Calamares::translatorLocaleName().name );
}

void
LanguageConfig::retranslate()
{
    m_model->retranslated();
    emit retranslated();
}

QString
LanguageConfig::pageTitle() const
{
    // The product's name, from branding, rather than baked into the source string: the same
    // versionedName()/productName() pair the greeting page reads, so a rebrand moves one file.
    const auto* branding = Calamares::Branding::instance();
    return tr( "Welcome to %1" ).arg( branding ? branding->productName() : QString() );
}

QString
LanguageConfig::pageLede() const
{
    return tr( "Pick the language you want to use while installing. This becomes the system "
               "language, and you can change it later in Settings." );
}

QString
LanguageConfig::prettyStatus() const
{
    // KEEPING (plan/33 §1, §8): the choice on this page configures the INSTALLER SESSION only —
    // there is no `languagesetup` job, and nothing here is ever applied to the target — so on a
    // kept disk the row this page owns must say that rather than name a language nobody is
    // installing. The page itself is unaware of keeping otherwise: it asks GlobalStorage
    // directly, here, rather than carrying a property nothing else on this page would use.
    auto* gs = Calamares::JobQueue::instance() ? Calamares::JobQueue::instance()->globalStorage()
                                              : nullptr;
    if ( gs && gs->value( QStringLiteral( "diskKeepData" ) ).toBool() )
    {
        return tr( "Kept as it is on this computer" );
    }
    if ( m_currentIndex < 0 || m_currentIndex >= m_model->rowCount() )
    {
        return {};
    }
    return m_model->entries().at( m_currentIndex ).label;
}

QString
LanguageConfig::currentId() const
{
    if ( m_currentIndex < 0 || m_currentIndex >= m_model->rowCount() )
    {
        return {};
    }
    return m_model->entries().at( m_currentIndex ).id;
}

#include "moc_LanguageConfig.cpp"
