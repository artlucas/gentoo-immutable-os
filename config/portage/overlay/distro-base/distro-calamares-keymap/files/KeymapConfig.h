/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The keyboard page's state (plan/28 §6).
 *
 * WHAT THIS REPLACES. Calamares' `keyboard` module: two list views, a model picker, and a drawn
 * keyboard preview, in Breeze, beside nine pages that are not. Its layout enumeration lives in
 * keyboardwidget/keyboardglobal.cpp and its preview in keyboardwidget/keyboardpreview.cpp —
 * neither installed, both QWidget.
 *
 * TWO THINGS HAD TO BE REBUILT AND THEY WERE REBUILT DIFFERENTLY.
 *
 * 1. THE LIST OF LAYOUTS is read here, from /usr/share/X11/xkb/rules/evdev.xml, with
 *    QXmlStreamReader. That file is x11-misc/xkeyboard-config's registry — the same file
 *    upstream's keyboardglobal reads — and the shape this needs from it is forty lines of
 *    <layout><configItem><name>/<description> and a <variantList> beside it. Copying 300 lines of
 *    somebody else's parser to get that was weighed against writing it, and writing it won: the
 *    greeting page had just finished paying off a vendoring (plan/28 §2), and a vendored file
 *    that has to be diffed against a future release is a debt with interest.
 *
 * 2. THE PREVIEW IS NOT A DRAWING OF A KEYBOARD. Upstream paints one by parsing the xkb SYMBOLS
 *    files, following their include directives, and mapping keysym names to characters through a
 *    table — which is where most of those 600 lines go, and every one of them is a second
 *    implementation of something libxkbcommon already does exactly.
 *
 *    So this asks libxkbcommon. xkb_keymap_new_from_names() with the chosen layout and variant,
 *    then xkb_state_key_get_utf8() for the thirty keycodes of the three alphanumeric rows. What
 *    comes back is what the X server would produce for those keys under that layout, because it
 *    is the same library answering. It is also the only honest preview this installer can show:
 *    the LIVE session's layout is not changed by this page — the medium runs kwin_wayland with
 *    --locale1, so switching it would mean talking to systemd-localed over polkit and changing
 *    the machine the user is standing at — so a "type here to check it" box would be testing the
 *    layout they already have. The preview is the check.
 */
#pragma once

#include <QAbstractListModel>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>
#include <QVector>

/*! A layout, or a variant of one. Both lists are this shape: a key the job writes and a
 *  description a person reads. */
class KeymapListModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles
    {
        NameRole = Qt::DisplayRole,
        KeyRole = Qt::UserRole,
    };

    struct Entry
    {
        QString key;
        QString name;
    };

    explicit KeymapListModel( QObject* parent = nullptr );

    void setEntries( const QVector< Entry >& entries );
    const QVector< Entry >& entries() const { return m_entries; }
    int indexOfKey( const QString& key ) const;

    int rowCount( const QModelIndex& parent = QModelIndex() ) const override;
    QVariant data( const QModelIndex& index, int role ) const override;
    QHash< int, QByteArray > roleNames() const override;

private:
    QVector< Entry > m_entries;
};

class KeymapConfig : public QObject
{
    Q_OBJECT

    Q_PROPERTY( QAbstractItemModel* layouts READ layoutsModel CONSTANT )
    Q_PROPERTY( QAbstractItemModel* variants READ variantsModel CONSTANT )

    Q_PROPERTY( QString layout READ layout WRITE setLayout NOTIFY selectionChanged )
    Q_PROPERTY( QString variant READ variant WRITE setVariant NOTIFY selectionChanged )

    /*! Three rows of ten keys, as they would type under the current selection. A list of lists,
     *  which QML reads as a model of models. */
    Q_PROPERTY( QVariantList preview READ preview NOTIFY selectionChanged )

    Q_PROPERTY( QString pageTitle READ pageTitle NOTIFY retranslated )
    Q_PROPERTY( QString pageLede READ pageLede NOTIFY retranslated )
    Q_PROPERTY( QString layoutLabel READ layoutLabel NOTIFY retranslated )
    Q_PROPERTY( QString variantLabel READ variantLabel NOTIFY retranslated )
    Q_PROPERTY( QString previewLabel READ previewLabel NOTIFY retranslated )
    /*! Said when the registry could not be read at all, which is a medium missing
     *  x11-misc/xkeyboard-config — a state the page has to be able to describe, because the
     *  alternative is two empty dropdowns and no explanation. */
    Q_PROPERTY( QString noLayoutsText READ noLayoutsText NOTIFY retranslated )
    Q_PROPERTY( bool haveLayouts READ haveLayouts NOTIFY selectionChanged )

public:
    explicit KeymapConfig( QObject* parent = nullptr );

    void setConfigurationMap( const QVariantMap& configurationMap );

    QAbstractItemModel* layoutsModel() const;
    QAbstractItemModel* variantsModel() const;

    QString layout() const { return m_layout; }
    void setLayout( const QString& layout );
    QString variant() const { return m_variant; }
    void setVariant( const QString& variant );

    QVariantList preview() const { return m_preview; }
    bool haveLayouts() const;

    QString pageTitle() const { return tr( "Set up your keyboard" ); }
    QString pageLede() const
    {
        return tr( "Pick the layout printed on your keys. The preview below shows what they will "
                   "type once the installed system starts." );
    }
    QString layoutLabel() const { return tr( "Layout" ); }
    QString variantLabel() const { return tr( "Variant" ); }
    QString previewLabel() const { return tr( "Preview" ); }
    QString noLayoutsText() const
    {
        return tr( "No keyboard layouts could be read from this medium, so the installed system "
                   "will keep the layout this one booted with." );
    }
    /*! The name a variant with no name has — every layout has a plain form, and the registry does
     *  not list it. */
    QString defaultVariantText() const { return tr( "Default" ); }

    /*! What the summary page shows. */
    QString prettyStatus() const;

    /*! Writes `keyboardLayout` and `keyboardVariant`, which `keyboardsetup` reads. Upstream's
     *  SetKeyboardLayoutJob took them from its own Config rather than from GlobalStorage, so
     *  these two keys are ours — and they are named for what they are. */
    void publish() const;

public slots:
    void retranslate();

signals:
    void selectionChanged();
    void retranslated();

private:
    /*! Reads /usr/share/X11/xkb/rules/evdev.xml once. Leaves both lists empty and logs if it
     *  cannot, which is what haveLayouts() reports. */
    void loadRegistry();
    /*! Refills the variant list for the current layout, and clamps the variant into it. */
    void refreshVariants();
    /*! Asks libxkbcommon what the three rows type under the current selection. */
    void refreshPreview();

    KeymapListModel* m_layouts;
    KeymapListModel* m_variants;
    /*! layout key -> its variants, as read from the registry. */
    QHash< QString, QVector< KeymapListModel::Entry > > m_variantsByLayout;

    QString m_layout;
    QString m_variant;
    QVariantList m_preview;
};
