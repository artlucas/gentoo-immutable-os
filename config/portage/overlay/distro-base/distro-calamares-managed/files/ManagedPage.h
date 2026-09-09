/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#pragma once

#include <QWidget>

class QCheckBox;
class QLabel;
class QLineEdit;

/*!
 * A deliberately plain widgets page. Calamares' *q modules render QML from
 * /usr/share/calamares/qml/, which is a second install path, a second set of import paths and a
 * second thing to get wrong at runtime; this page has three controls and needs none of it.
 */
class ManagedPage : public QWidget
{
    Q_OBJECT

public:
    explicit ManagedPage( QWidget* parent = nullptr );

    bool isEnrolmentRequested() const;
    QString code() const;
    QString deviceName() const;

    void setOrganisationHint( const QString& hint );

private:
    QCheckBox* m_enable;
    QLineEdit* m_code;
    QLineEdit* m_name;
    QLabel* m_hint;
};
