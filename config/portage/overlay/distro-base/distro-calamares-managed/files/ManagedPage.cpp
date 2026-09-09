/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "ManagedPage.h"

#include <QCheckBox>
#include <QLabel>
#include <QLineEdit>
#include <QVBoxLayout>
#include <QFormLayout>

ManagedPage::ManagedPage( QWidget* parent )
    : QWidget( parent )
{
    auto* layout = new QVBoxLayout( this );

    auto* heading = new QLabel( tr( "Manage this computer with an organisation" ), this );
    QFont headingFont = heading->font();
    headingFont.setPointSize( headingFont.pointSize() + 4 );
    heading->setFont( headingFont );
    layout->addWidget( heading );

    auto* blurb = new QLabel(
        tr( "A household or a small business can create the accounts on this computer and decide "
            "what they are allowed to do. If you have an enrolment code, enter it here. You can "
            "also do this later, from System Settings." ),
        this );
    blurb->setWordWrap( true );
    layout->addWidget( blurb );

    m_enable = new QCheckBox( tr( "Enrol this computer with an organisation" ), this );
    layout->addWidget( m_enable );

    auto* form = new QFormLayout();
    m_code = new QLineEdit( this );
    m_code->setPlaceholderText( QStringLiteral( "K7QF-9M2B" ) );
    // Typed by a human off a phone screen, so it is short and case-insensitive (plan/19 §5.2).
    // Upper-casing here saves an error the control plane would otherwise have to explain.
    connect( m_code, &QLineEdit::textChanged, this, [ this ]( const QString& text ) {
        const QString upper = text.toUpper();
        if ( upper != text )
        {
            m_code->setText( upper );
        }
    } );
    form->addRow( tr( "Enrolment code:" ), m_code );

    m_name = new QLineEdit( this );
    m_name->setPlaceholderText( tr( "kitchen-pc" ) );
    form->addRow( tr( "Name for this computer:" ), m_name );
    layout->addLayout( form );

    m_hint = new QLabel( this );
    m_hint->setWordWrap( true );
    layout->addWidget( m_hint );

    // THE SENTENCE THAT MAKES T-MAN-4 A FEATURE RATHER THAN A SURPRISE. plan/18 §7.4's lesson is
    // that an installer must not fail because a network service is down; saying so on the page
    // is what turns "it did not enrol" from an apparent broken install into an expected outcome
    // with a one-command fix.
    auto* reassurance = new QLabel(
        tr( "If the organisation cannot be reached during installation, the install still "
            "completes. This computer will say so, and one command finishes the enrolment." ),
        this );
    reassurance->setWordWrap( true );
    QFont small = reassurance->font();
    small.setItalic( true );
    reassurance->setFont( small );
    layout->addWidget( reassurance );

    layout->addStretch();

    m_code->setEnabled( false );
    m_name->setEnabled( false );
    connect( m_enable, &QCheckBox::toggled, m_code, &QLineEdit::setEnabled );
    connect( m_enable, &QCheckBox::toggled, m_name, &QLineEdit::setEnabled );
}

bool
ManagedPage::isEnrolmentRequested() const
{
    return m_enable->isChecked() && !m_code->text().trimmed().isEmpty();
}

QString
ManagedPage::code() const
{
    return m_code->text().trimmed();
}

QString
ManagedPage::deviceName() const
{
    return m_name->text().trimmed();
}

void
ManagedPage::setOrganisationHint( const QString& hint )
{
    m_hint->setText( hint );
    m_hint->setVisible( !hint.isEmpty() );
}
