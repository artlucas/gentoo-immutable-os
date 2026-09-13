/*
 * VENDORED FROM CALAMARES 3.4.2, src/modules/welcome/checker/ResultDelegate.h (plan/23 §2).
 *
 * These three classes are the stock welcome page's requirements box. They are not in libcalamaresui
 * and no header of theirs is installed, so a module that wants the box has to carry the source —
 * which is also why the class names, the layout and every translatable string below are left
 * exactly as upstream wrote them: the diff against a future Calamares release should be this
 * header and the edit named under it, and nothing else.
 *
 * NOT ONE LINE IS CHANGED in this file. It refers to no config object, only to
 * Calamares::RequirementsModel's roles and to libcalamaresui's painting helpers, both of which are
 * installed public headers.
 */
/* === This file is part of Calamares - <https://calamares.io> ===
 *
 *   SPDX-FileCopyrightText: 2022 Adriaan de Groot <groot@kde.org>
 *   SPDX-License-Identifier: GPL-3.0-or-later
 *
 *   Calamares is Free Software: see the License-Identifier above.
 *
 */

#ifndef WELCOME_CHECKER_RESULTDELEGATE_HH
#define WELCOME_CHECKER_RESULTDELEGATE_HH

#include <QStyledItemDelegate>

#include "modulesystem/RequirementsModel.h"

/**
 * @brief Class for drawing (un)satisfied requirements
 */
class ResultDelegate : public QStyledItemDelegate
{
public:
    using QStyledItemDelegate::QStyledItemDelegate;
    ResultDelegate( QObject* parent, Calamares::RequirementsModel::Roles text )
        : QStyledItemDelegate( parent )
        , m_textRole( text )
    {
    }

protected:
    QSize sizeHint( const QStyleOptionViewItem& option, const QModelIndex& index ) const override;
    void paint( QPainter* painter, const QStyleOptionViewItem& option, const QModelIndex& index ) const override;

    int m_textRole = Calamares::RequirementsModel::Name;
};

#endif  // PROGRESSTREEDELEGATE_H
