/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * The summary page's state (plan/28 §6).
 *
 * WHAT THIS REPLACES. Calamares' own `summary` module, which renders each preceding view step's
 * prettyDescription() into a QWidget list through a SummaryModel that lives inside that module
 * and is not installed. This one asks the steps the same question and draws the answers as the
 * design system's label/value table.
 *
 * NO STATE OF ITS OWN, AND THAT IS THE POINT. Every row is another step's prettyStatus(),
 * collected at onActivate(). A summary page that cached anything would be a page that could
 * disagree with the pages behind it — and this is the last screen before an erase.
 */
#pragma once

#include <QAbstractListModel>
#include <QObject>
#include <QString>
#include <QVector>

namespace Calamares
{
class ViewStep;
}

/*! One row per preceding step: its name and what it says it is going to do. */
class ReviewModel : public QAbstractListModel
{
    Q_OBJECT

public:
    enum Roles
    {
        LabelRole = Qt::DisplayRole,
        ValueRole = Qt::UserRole + 1,
    };

    struct Entry
    {
        QString label;
        QString value;
    };

    explicit ReviewModel( QObject* parent = nullptr );

    void setEntries( const QVector< Entry >& entries );

    int rowCount( const QModelIndex& parent = QModelIndex() ) const override;
    QVariant data( const QModelIndex& index, int role ) const override;
    QHash< int, QByteArray > roleNames() const override;

private:
    QVector< Entry > m_entries;
};

class ReviewConfig : public QObject
{
    Q_OBJECT

    Q_PROPERTY( QAbstractItemModel* rows READ rowsModel CONSTANT )

    Q_PROPERTY( QString pageTitle READ pageTitle NOTIFY retranslated )
    Q_PROPERTY( QString pageLede READ pageLede NOTIFY retranslated )
    /*! The danger panel's heading, which NAMES THE DISK — the whole reason this page is in the
     *  sequence. It is composed in C++ from GlobalStorage's `device`, because a page that said
     *  "this erases the selected disk" would be a page nobody has to read. */
    Q_PROPERTY( QString eraseTitle READ eraseTitle NOTIFY rowsChanged )
    Q_PROPERTY( QString eraseBody READ eraseBody NOTIFY retranslated )

    Q_PROPERTY( QString unknownDiskText READ unknownDiskText NOTIFY retranslated )

public:
    explicit ReviewConfig( QObject* parent = nullptr );

    QAbstractItemModel* rowsModel() const;

    /*! Re-reads every preceding step. Called from onActivate(), never cached — see the header. */
    void collect( const Calamares::ViewStep* upToHere );

    QString pageTitle() const { return tr( "Ready to install" ); }
    QString pageLede() const
    {
        return tr( "Nothing has changed on your computer yet. This is the last step before the "
                   "installer writes to the disk." );
    }
    QString eraseTitle() const;
    QString eraseBody() const
    {
        return tr( "Every partition, file and operating system on that drive will be removed. "
                   "Other drives are left alone." );
    }
    QString unknownDiskText() const { return tr( "the selected disk" ); }

public slots:
    void retranslate();

signals:
    void retranslated();
    void rowsChanged();

private:
    ReviewModel* m_rows;
};
