/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The language page's state (plan/22).
 *
 * TWO OBJECTS, BOTH SMALL. LanguageModel is the list of languages this image can actually speak;
 * LanguageConfig is which row is chosen and the one word drawn above the list.
 *
 * WHAT LEFT THIS FILE IN plan/23. The greeting, the requirements verdict and the screen-switching
 * they needed are the `greeting` module's now. What is left is a page that asks one question, and
 * the object below has no state beyond the answer to it.
 *
 * WHY WE HAVE A MODEL OF OUR OWN AT ALL, when libcalamares ships one. Calamares'
 * Locale::TranslationsModel lists all 82 translations compiled into the binary and exposes
 * exactly two roles, `label` and `englishLabel` — no locale id, by way of a localeIds() accessor
 * that is neither a property nor Q_INVOKABLE. Measured against this medium's own Qt 6.11.1
 * (plan/22 §2a), two of those 82 pairs are identical in BOTH roles: `ja` and `ja-Hira` both
 * render 日本語, and `zh` and `zh_CN` both render 简体中文 while their catalogues differ in
 * completeness. A page given that model cannot tell those rows apart, cannot relabel them, and
 * cannot drop one — so it cannot keep the promise this page is for. Ours is nine rows out of
 * config/languages.conf, each one a language the INSTALLED machine can speak, with the label
 * written by a person.
 */
#pragma once

#include <QAbstractListModel>
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QVector>

class LanguageModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles
    {
        /*! What the user reads: the native name, from column 3 of config/languages.conf. */
        LabelRole = Qt::DisplayRole,
        /*! The language's name in the language currently selected — "ドイツ語" once 日本語 is
         *  chosen, not "German". Column 4 is the English SOURCE string, translated through the
         *  LanguageNames context. */
        NameRole = Qt::UserRole + 1,
        /*! The Calamares translation id (de, pt_BR). Exposed because it is the thing upstream's
         *  model withholds, and because the tests assert on it. */
        IdRole,
        /*! The glibc locale this row installs (de_DE.UTF-8). */
        LocaleRole,
        /*! The same locale with the encoding cut off (de_DE), which is what the row DRAWS under
         *  the native name (plan/28). Every locale in config/languages.conf is UTF-8, so the
         *  suffix is nine identical characters carrying no information — and this is a mono line
         *  in a 2-up grid, where the width it costs is width the native name does not get. A role
         *  rather than a .replace() in the QML: it is a fact about the entry, and the page should
         *  not be deciding what a locale name looks like. */
        LocaleShortRole,
    };

    struct Entry
    {
        QString id;
        QString locale;
        QString label;
        QString english;
    };

    explicit LanguageModel( QObject* parent = nullptr );

    void setEntries( const QVector< Entry >& entries );
    const QVector< Entry >& entries() const { return m_entries; }

    int rowCount( const QModelIndex& parent = QModelIndex() ) const override;
    QVariant data( const QModelIndex& index, int role ) const override;
    QHash< int, QByteArray > roleNames() const override;

    /*! Re-reads every NameRole. Called on a language change instead of rebuilding the model,
     *  because a reset would take the ListView's currentIndex to 0 with it — and this list's
     *  currentIndex IS the language, so resetting it would change the language that caused the
     *  reset. dataChanged leaves the selection exactly where the user put it. */
    void retranslated();

    /*! -1 when there is no such row. */
    int indexOfId( const QString& id ) const;
    /*! Best row for a system locale like "de_AT": exact id first, then the language alone. */
    int bestIndexFor( const QString& localeName ) const;

private:
    QVector< Entry > m_entries;
};

class LanguageConfig : public QObject
{
    Q_OBJECT

public:
    // ---- the list ----------------------------------------------------------------------------
    Q_PROPERTY( QAbstractItemModel* languages READ languagesModel CONSTANT )
    /*! THE SELECTED ROW, AND THE ONE THE PAGE DRAWS AS SELECTED ARE THE SAME NUMBER. The QML's
     *  ListView owns the highlight, so Language.qml pushes its currentIndex here and puts back
     *  whatever this setter accepted — see the long block around `currentIndex: -1` there for
     *  what went wrong when the two were allowed to differ. */
    Q_PROPERTY( int currentIndex READ currentIndex WRITE setCurrentIndex NOTIFY currentIndexChanged )

    /*! The page's heading and its opening sentence (plan/28).
     *
     *  THESE EXIST AGAINST AN ARGUMENT THIS FILE USED TO MAKE, and the argument was not wrong: a
     *  sentence of English above a language picker explains nothing to the people the screen is
     *  for, and a list of nine languages written in those languages explains itself to everybody
     *  who can see it. What overrode it is that the installer now paints one design end to end,
     *  and every other page opens with a heading and a lede; a first page that opened with a bare
     *  list would read as a page that had not finished loading.
     *
     *  Both are retranslated with everything else, so the moment the highlight moves they are in
     *  the newly chosen language — which is the half of the old objection that could be answered.
     *  tr() on the Config, never qsTr() in the QML: the builder's lupdate cannot see QML at all
     *  (plan/27 §1). */
    Q_PROPERTY( QString pageTitle READ pageTitle NOTIFY retranslated )
    Q_PROPERTY( QString pageLede READ pageLede NOTIFY retranslated )

    explicit LanguageConfig( QObject* parent = nullptr );

    void setConfigurationMap( const QVariantMap& configurationMap );

    QAbstractItemModel* languagesModel() const;
    int currentIndex() const { return m_currentIndex; }
    void setCurrentIndex( int index );

    /* headerWord() was here: tr("Language"), drawn above the list as the page's only text.
     * plan/28 replaced it with pageTitle/pageLede, which say more in the same place, and a
     * property nothing reads is a translated string that eight catalogues would go on carrying
     * for a label that is not on screen. Its entry was removed from those catalogues with it —
     * check 4 in scripts/lib/check-translations.py requires every <source> to still exist in the
     * sources, so leaving it behind would have failed the build rather than merely rotting. */
    QString pageTitle() const;
    QString pageLede() const;

    /*! What the summary page shows. */
    QString prettyStatus() const;

    /*! The chosen language's id, for GlobalStorage and for the tests. */
    QString currentId() const;

    /*! Writes the chosen language into GlobalStorage's localeConf map, as the key `LANG`.
     *  Called on every selection and again from onLeave(), for the reason the accounts page
     *  gives: onLeave() is the contract, and it costs nothing to keep both. */
    void publish() const;

public slots:
    /*! Re-reads the model's NameRole and re-emits every derived string. Wired to Calamares'
     *  Retranslator in the constructor. */
    void retranslate();

signals:
    void currentIndexChanged();
    void retranslated();

private:
    LanguageModel* m_model;
    int m_currentIndex = -1;
};
