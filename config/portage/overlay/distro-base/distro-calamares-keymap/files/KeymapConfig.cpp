/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "KeymapConfig.h"

#include "GlobalStorage.h"
#include "JobQueue.h"
#include "utils/Logger.h"
#include "utils/Retranslator.h"
#include "utils/Variant.h"

#include <QFile>
#include <QXmlStreamReader>

#include <xkbcommon/xkbcommon.h>

namespace
{
/*! x11-misc/xkeyboard-config's registry. `evdev` is the rule set every Linux console and every
 *  Wayland compositor uses; `base.xml` is the same file for the pre-evdev world and is not what
 *  this medium's keyboards are described by. */
const char* const REGISTRY = "/usr/share/X11/xkb/rules/evdev.xml";

/*! The three alphanumeric rows, in X11 keycodes — which is what xkbcommon numbers keys by when a
 *  keymap is built from names. AD01..AD10 is the QWERTY row, AC01..AC10 the home row, AB01..AB10
 *  the row under it; the numbers are the evdev codes plus 8 and have been fixed for as long as
 *  X11 has existed. Ten per row, because the eleventh and twelfth keys of a row are where layouts
 *  stop agreeing about how many there are. */
struct Row
{
    int first;
    int count;
};
constexpr Row ROWS[] = { { 24, 10 }, { 38, 10 }, { 52, 10 } };
}  // namespace

// ================================ KeymapListModel ============================================

KeymapListModel::KeymapListModel( QObject* parent )
    : QAbstractListModel( parent )
{
}

void
KeymapListModel::setEntries( const QVector< Entry >& entries )
{
    beginResetModel();
    m_entries = entries;
    endResetModel();
}

int
KeymapListModel::indexOfKey( const QString& key ) const
{
    for ( int i = 0; i < m_entries.count(); ++i )
    {
        if ( m_entries.at( i ).key == key )
        {
            return i;
        }
    }
    return -1;
}

int
KeymapListModel::rowCount( const QModelIndex& parent ) const
{
    return parent.isValid() ? 0 : static_cast< int >( m_entries.count() );
}

QVariant
KeymapListModel::data( const QModelIndex& index, int role ) const
{
    if ( !index.isValid() || index.row() < 0 || index.row() >= m_entries.count() )
    {
        return {};
    }
    const Entry& e = m_entries.at( index.row() );
    switch ( role )
    {
    case NameRole:
        return e.name;
    case KeyRole:
        return e.key;
    default:
        return {};
    }
}

QHash< int, QByteArray >
KeymapListModel::roleNames() const
{
    return { { NameRole, "name" }, { KeyRole, "key" } };
}

// ================================ KeymapConfig ===============================================

KeymapConfig::KeymapConfig( QObject* parent )
    : QObject( parent )
    , m_layouts( new KeymapListModel( this ) )
    , m_variants( new KeymapListModel( this ) )
{
    CALAMARES_RETRANSLATE_SLOT( &KeymapConfig::retranslate );
    loadRegistry();
}

void
KeymapConfig::loadRegistry()
{
    // BRACES, NOT PARENTHESES. `QFile f( QLatin1String( REGISTRY ) );` is a function declaration,
    // not a variable — C++'s most vexing parse, which g++ reports as a warning and then fails on
    // three lines later with "request for member 'open' in 'f', which is of non-class type".
    QFile f { QLatin1String( REGISTRY ) };
    if ( !f.open( QIODevice::ReadOnly ) )
    {
        // NOT FATAL, and the page says so rather than showing two empty dropdowns: a medium
        // without x11-misc/xkeyboard-config cannot offer a layout, and the installed system
        // keeping the one the medium booted with is a defensible outcome. What is not defensible
        // is a page that looks broken with nothing in the log.
        cWarning() << "keymap: cannot read" << REGISTRY << "-" << f.errorString()
                   << "- the page will offer no layouts.";
        return;
    }

    QVector< KeymapListModel::Entry > layouts;
    QXmlStreamReader xml( &f );

    // ONE PASS, AND THE STRUCTURE IS THE PARSER. The registry nests
    // <layoutList><layout><configItem><name|description> and, beside that configItem,
    // <variantList><variant><configItem><name|description>. The only ambiguity is that a layout
    // and its variants use the same element names, so the depth of the <configItem> is what says
    // which is being read — tracked here as `inVariantList` rather than by counting elements.
    QString layoutKey;
    QString layoutName;
    bool inVariantList = false;
    QString variantKey;
    QString variantName;

    while ( !xml.atEnd() )
    {
        xml.readNext();
        if ( xml.isStartElement() )
        {
            const QStringView name = xml.name();
            if ( name == QLatin1String( "layout" ) )
            {
                layoutKey.clear();
                layoutName.clear();
                inVariantList = false;
            }
            else if ( name == QLatin1String( "variantList" ) )
            {
                inVariantList = true;
            }
            else if ( name == QLatin1String( "variant" ) )
            {
                variantKey.clear();
                variantName.clear();
            }
            else if ( name == QLatin1String( "name" ) )
            {
                ( inVariantList ? variantKey : layoutKey ) = xml.readElementText();
            }
            else if ( name == QLatin1String( "description" ) )
            {
                ( inVariantList ? variantName : layoutName ) = xml.readElementText();
            }
        }
        else if ( xml.isEndElement() )
        {
            const QStringView name = xml.name();
            if ( name == QLatin1String( "variant" ) && !variantKey.isEmpty() )
            {
                m_variantsByLayout[ layoutKey ].append(
                    { variantKey, variantName.isEmpty() ? variantKey : variantName } );
            }
            else if ( name == QLatin1String( "variantList" ) )
            {
                inVariantList = false;
            }
            else if ( name == QLatin1String( "layout" ) && !layoutKey.isEmpty() )
            {
                layouts.append( { layoutKey, layoutName.isEmpty() ? layoutKey : layoutName } );
            }
        }
    }

    if ( xml.hasError() )
    {
        // Partial results are kept. A truncated registry still describes the layouts it got
        // through, and an installer offering forty of them is better than one offering none.
        cWarning() << "keymap:" << REGISTRY << "did not parse cleanly:" << xml.errorString()
                   << "- read" << layouts.count() << "layout(s) before the error.";
    }

    m_layouts->setEntries( layouts );
    cDebug() << "keymap: read" << layouts.count() << "layouts from" << REGISTRY;
}

void
KeymapConfig::setConfigurationMap( const QVariantMap& configurationMap )
{
    // The default pin, before the user chooses. `us` is what the image ships as KEYMAP in
    // /etc/vconsole.conf, so this is "unchanged" rather than a guess.
    m_layout = Calamares::getString( configurationMap, QStringLiteral( "layout" ) );
    m_variant = Calamares::getString( configurationMap, QStringLiteral( "variant" ) );
    if ( m_layout.isEmpty() )
    {
        m_layout = QStringLiteral( "us" );
    }

    // If the registry has no such layout — a medium with a cut-down xkeyboard-config, or a typo
    // in the .conf — fall back to whatever it DOES have rather than publishing a layout the
    // installed system cannot load.
    if ( m_layouts->rowCount() > 0 && m_layouts->indexOfKey( m_layout ) < 0 )
    {
        const QString was = m_layout;
        m_layout = m_layouts->entries().first().key;
        cWarning() << "keymap: the configured default layout" << was << "is not in the registry;"
                   << "the page opened on" << m_layout << "instead.";
    }

    refreshVariants();
    refreshPreview();
    emit selectionChanged();
}

QAbstractItemModel*
KeymapConfig::layoutsModel() const
{
    return m_layouts;
}

QAbstractItemModel*
KeymapConfig::variantsModel() const
{
    return m_variants;
}

bool
KeymapConfig::haveLayouts() const
{
    return m_layouts->rowCount() > 0;
}

void
KeymapConfig::setLayout( const QString& layout )
{
    if ( layout.isEmpty() || layout == m_layout )
    {
        return;
    }
    if ( m_layouts->indexOfKey( layout ) < 0 )
    {
        cWarning() << "keymap: refused" << layout << "- not a layout in the registry";
        return;
    }
    m_layout = layout;
    // THE VARIANT DOES NOT SURVIVE A LAYOUT CHANGE. "dvorak" means something under `us` and
    // nothing under `de`, and a variant carried across would be published as a pair xkb cannot
    // load — which fails at first boot, on the installed machine, not here.
    m_variant.clear();
    refreshVariants();
    refreshPreview();
    emit selectionChanged();
}

void
KeymapConfig::setVariant( const QString& variant )
{
    if ( variant == m_variant )
    {
        return;
    }
    // The empty string IS a value: it is the layout's plain form, which the registry does not
    // list and which the page offers as the first row.
    if ( !variant.isEmpty() && m_variants->indexOfKey( variant ) < 0 )
    {
        cWarning() << "keymap: refused variant" << variant << "- not offered under" << m_layout;
        return;
    }
    m_variant = variant;
    refreshPreview();
    emit selectionChanged();
}

void
KeymapConfig::refreshVariants()
{
    // The plain form first, with an empty key — every layout has one and the registry lists only
    // the departures from it.
    QVector< KeymapListModel::Entry > entries { { QString(), defaultVariantText() } };
    entries += m_variantsByLayout.value( m_layout );
    m_variants->setEntries( entries );

    if ( !m_variant.isEmpty() && m_variants->indexOfKey( m_variant ) < 0 )
    {
        m_variant.clear();
    }
}

void
KeymapConfig::refreshPreview()
{
    m_preview.clear();

    // ONE CONTEXT PER REFRESH, and it is deliberately not cached: this runs when a human moves a
    // dropdown, at most a few times per install, and a cached xkb_context is a lifetime to get
    // wrong in a plugin Calamares unloads.
    xkb_context* ctx = xkb_context_new( XKB_CONTEXT_NO_FLAGS );
    if ( !ctx )
    {
        cWarning() << "keymap: xkb_context_new failed; the preview will be empty.";
        return;
    }

    const QByteArray layout = m_layout.toUtf8();
    const QByteArray variant = m_variant.toUtf8();
    xkb_rule_names names {};
    names.rules = "evdev";
    names.model = "pc105";
    names.layout = layout.constData();
    names.variant = variant.isEmpty() ? nullptr : variant.constData();
    names.options = nullptr;

    xkb_keymap* keymap
        = xkb_keymap_new_from_names( ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS );
    xkb_state* state = keymap ? xkb_state_new( keymap ) : nullptr;

    if ( state )
    {
        for ( const Row& row : ROWS )
        {
            QVariantList keys;
            for ( int i = 0; i < row.count; ++i )
            {
                char buf[ 32 ] = { 0 };
                // THE SAME CALL THE COMPOSITOR MAKES. Whatever comes back is what that key really
                // types under this layout, because it is xkbcommon answering rather than a table
                // of ours agreeing with it.
                const int n = xkb_state_key_get_utf8(
                    state, static_cast< xkb_keycode_t >( row.first + i ), buf, sizeof( buf ) );
                keys.append( n > 0 ? QString::fromUtf8( buf, n ) : QString() );
            }
            m_preview.append( QVariant( keys ) );
        }
    }
    else
    {
        // A layout xkbcommon will not compile is a layout the installed system would not load
        // either, so this is worth a line — but not a refusal: the registry offered it, and the
        // page showing an empty preview is a truer report than the page pretending it compiled.
        cWarning() << "keymap: xkbcommon could not compile" << m_layout
                   << ( m_variant.isEmpty() ? QString() : QStringLiteral( "(%1)" ).arg( m_variant ) )
                   << "- the preview will be empty.";
    }

    if ( state )
    {
        xkb_state_unref( state );
    }
    if ( keymap )
    {
        xkb_keymap_unref( keymap );
    }
    xkb_context_unref( ctx );
}

QString
KeymapConfig::prettyStatus() const
{
    // KEEPING (plan/33 §1, §8): this page's answer configures the INSTALLER SESSION only — the
    // kept system keeps its own keyboard, and `keyboardsetup` stands down entirely under keep —
    // so the summary row must say that rather than name a layout that will not be applied.
    auto* gs = Calamares::JobQueue::instance() ? Calamares::JobQueue::instance()->globalStorage()
                                              : nullptr;
    if ( gs && gs->value( QStringLiteral( "diskKeepData" ) ).toBool() )
    {
        return tr( "Kept as it is on this computer" );
    }
    if ( m_layout.isEmpty() )
    {
        return {};
    }
    const int at = m_layouts->indexOfKey( m_layout );
    const QString name = at >= 0 ? m_layouts->entries().at( at ).name : m_layout;
    if ( m_variant.isEmpty() )
    {
        return name;
    }
    const int vat = m_variants->indexOfKey( m_variant );
    const QString vname = vat >= 0 ? m_variants->entries().at( vat ).name : m_variant;
    return name + QStringLiteral( " · " ) + vname;
}

void
KeymapConfig::publish() const
{
    auto* gs = Calamares::JobQueue::instance() ? Calamares::JobQueue::instance()->globalStorage()
                                              : nullptr;
    if ( !gs )
    {
        return;
    }
    gs->insert( QStringLiteral( "keyboardLayout" ), m_layout );
    gs->insert( QStringLiteral( "keyboardVariant" ), m_variant );
}

void
KeymapConfig::retranslate()
{
    emit retranslated();
    // The "Default" variant row is a tr() string sitting in a model, so the list has to be
    // rebuilt rather than merely re-read. The layout and variant DESCRIPTIONS are
    // xkeyboard-config's own and are not translated by Qt at all — they come out of the registry
    // in one language, which is the same language the X server would report them in.
    refreshVariants();
    emit selectionChanged();
}

#include "moc_KeymapConfig.cpp"
