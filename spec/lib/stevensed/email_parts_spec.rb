# frozen_string_literal: true

describe Stevensed::EmailParts do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:, first_name: 'Morgan', last_name: 'Hale') }
  let(:template) { create(:template, account:, author: user, name: 'Enrollment agreement') }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: user) }
  let(:submitter) { submission.submitters.first }

  before { submitter.update!(name: 'Jordan Rivera') }

  def invitation(reminder: false)
    SubmitterMailer.invitation_email(submitter, reminder:).deliver_now

    ActionMailer::Base.deliveries.last
  end

  def html_of(mail)
    mail.html_part.body.decoded
  end

  def save_template_parts(key, parts)
    template.update!(preferences: template.preferences.merge('email_parts' => { key => parts }))
  end

  def save_account_parts(key, value)
    create(:account_config, account:, key:, value:)
  end

  it 'renders saved parts inside the branded frame' do
    save_account_parts(AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY,
                       'subject' => 'Please sign {document.name}',
                       'heading' => 'Agreement for {submitter.name}',
                       'intro' => 'Please **review** the agreement from {requester.name}.',
                       'closing' => 'With thanks, the {requester.office}.')

    mail = invitation
    html = html_of(mail)

    expect(mail.subject).to eq('Please sign Enrollment agreement')
    expect(html).to include('Agreement for Jordan Rivera')
    expect(html).to include('Please <strong>review</strong> the agreement from Morgan Hale, StevensED.')
    expect(html).to include("With thanks, the #{Stevensed::ORGANIZATION}.")
    expect(html).to include('Requested by')
    expect(html).to include('Review and sign')
    expect(html).to include('Please read the entire document before signing.')
    expect(html).to include('Questions may be sent by reply')
    expect(html).to include('This link is personal to you.')
  end

  it 'falls back to the StevensED default part by part' do
    save_account_parts(AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY, 'subject' => 'Custom subject')

    mail = invitation
    html = html_of(mail)

    expect(mail.subject).to eq('Custom subject')
    expect(html).to include('Re: Request for electronic signature, Enrollment agreement')
    expect(html).to include('You have been asked to review and sign the agreement below.')
    expect(html).to be_ascii_only
  end

  it 'uses the submit version for forms without signature fields' do
    signature_types = %w[signature initials]
    template.update!(fields: template.fields.reject { |f| signature_types.include?(f['type']) })
    submission.update!(template_fields: template.fields)

    save_account_parts(AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY,
                       'intro' => 'Sign this.', 'intro_submit' => 'Complete this form.')

    mail = invitation

    expect(mail.subject).to eq('StevensED: please complete "Enrollment agreement"')
    expect(html_of(mail)).to include('Complete this form.')
    expect(html_of(mail)).not_to include('Sign this.')
    expect(html_of(mail)).to include('Review and complete')
  end

  it 'prefers template parts over account parts, and role parts over both' do
    save_account_parts(AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY,
                       'heading' => 'Account heading', 'intro' => 'Account introduction.')
    save_template_parts(AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY,
                        'intro' => 'Template introduction.', 'closing' => 'Template closing.')

    html = html_of(invitation)

    expect(html).to include('Account heading')
    expect(html).to include('Template introduction.')
    expect(html).not_to include('Account introduction.')

    template.update!(preferences: template.preferences.merge(
      'email_parts_by_submitter' => { submitter.uuid => { 'closing' => 'Role closing.' } }
    ))

    html = html_of(invitation)

    expect(html).to include('Template introduction.')
    expect(html).to include('Role closing.')
    expect(html).not_to include('Template closing.')
  end

  it 'prefers the per-send message over template and account parts' do
    save_account_parts(AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY, 'intro' => 'Account introduction.')
    save_template_parts(AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY,
                        'intro' => 'Template introduction.', 'heading' => 'Template heading')

    message = EmailMessage.create!(account:, author: user, subject: 'Per-send subject', body: 'Per-send message.')
    submitter.update!(preferences: submitter.preferences.merge('email_message_uuid' => message.uuid))

    mail = invitation
    html = html_of(mail)

    expect(mail.subject).to eq('Per-send subject')
    expect(html).to include('Per-send message.')
    expect(html).to include('Template heading')
    expect(html).not_to include('Template introduction.')
    expect(html).to include('Requested by')
    expect(html).to include('Review and sign')
  end

  it 'renders a legacy free-form account body as before' do
    save_account_parts(AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY,
                       'subject' => 'Legacy subject', 'body' => 'Legacy body for {template.name}.')

    mail = invitation
    html = html_of(mail)

    expect(mail.subject).to eq('Legacy subject')
    expect(html).to include('Legacy body for Enrollment agreement.')
    expect(html).not_to include('Requested by')
  end

  it 'sends the reminder with its own parts' do
    html = html_of(mail = invitation(reminder: true))

    expect(mail.subject).to eq('StevensED reminder: please review and sign "Enrollment agreement"')
    expect(html).to include('This is a reminder that you have been asked to review and sign the agreement below.')

    save_account_parts(AccountConfig::SUBMITTER_INVITATION_REMINDER_EMAIL_KEY, 'intro' => 'A gentle reminder.')

    expect(html_of(invitation(reminder: true))).to include('A gentle reminder.')
  end

  it 'uses saved parts in the completion notice and the documents copy' do
    submitter.update!(completed_at: Time.current)
    allow(Submissions::EnsureResultGenerated).to receive(:call)
    allow(Submitters).to receive(:select_attachments_for_download).and_return([])

    save_account_parts(AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY,
                       'subject' => 'Done: {document.name}', 'intro' => 'Signed by {submission.submitters}.')
    save_template_parts(AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY,
                        'heading' => 'Your copy, {submitter.first_name}')

    SubmitterMailer.completed_email(submitter, user).deliver_now
    completed = ActionMailer::Base.deliveries.last

    expect(completed.subject).to eq('Done: Enrollment agreement')
    expect(html_of(completed)).to include('Signed by Jordan Rivera.')
    expect(html_of(completed)).to include('View submission')

    SubmitterMailer.documents_copy_email(submitter).deliver_now
    copy = ActionMailer::Base.deliveries.last

    expect(copy.subject).to eq('StevensED: your copy of "Enrollment agreement"')
    expect(html_of(copy)).to include('Your copy, Jordan')
    expect(html_of(copy)).to include('Download your copy')
  end

  it 'loads the StevensED defaults as editor text' do
    defaults = described_class.all_defaults(AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY)

    expect(defaults['subject']).to eq('StevensED: please review and sign "{document.name}"')
    expect(defaults['heading_submit']).to eq('Re: Request to complete {document.name}')
    expect(defaults['intro']).to eq('You have been asked to review and sign the agreement below.')
    expect(described_class.all_defaults(AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY)['subject'])
      .to eq('StevensED: "{document.name}" has been completed')
  end
end
