# frozen_string_literal: true

RSpec::Matchers.define_negated_matcher :not_change, :change

describe 'Email template editor' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:, email: 'staff.member@example.org') }
  let(:invitation_key) { AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY }

  before { sign_in(user) }

  def account_value(key)
    account.account_configs.find_by(key:)&.value
  end

  it 'shows the StevensED text in the editors when nothing is saved' do
    get settings_personalization_path

    expect(response.body).to include('You have been asked to review and sign the agreement below.')
    expect(response.body).to include('Re: Request for electronic signature, {document.name}')
    expect(response.body).to include('This is a reminder that you have been asked to review and sign')
    expect(response.body).to include('Document name')
    expect(response.body).not_to include('You are invited to sign a document')
  end

  it 'stores only the parts that differ from the default and drops a legacy body' do
    create(:account_config, account:, key: invitation_key,
                            value: { 'subject' => 'Old', 'body' => 'Old free-form body',
                                     'reply_to' => 'office@example.org' })

    defaults = Stevensed::EmailParts.all_defaults(invitation_key)

    post settings_personalization_path, params: {
      account_config: {
        key: invitation_key,
        value: defaults.merge('heading' => 'New heading for {document.name}', 'reply_to' => 'office@example.org')
      }
    }

    expect(account_value(invitation_key)).to eq('heading' => 'New heading for {document.name}',
                                                'reply_to' => 'office@example.org')
  end

  it 'resets the account version to the StevensED default and keeps other settings' do
    create(:account_config, account:, key: invitation_key,
                            value: { 'intro' => 'Custom introduction.', 'reply_to' => 'office@example.org' })

    delete settings_email_template_reset_path(invitation_key)

    expect(response).to redirect_to(settings_personalization_path)
    expect(account_value(invitation_key)).to eq('reply_to' => 'office@example.org')

    create(:account_config, account:, key: AccountConfig::SUBMITTER_VIEW_INVITATION_EMAIL_KEY,
                            value: { 'intro' => 'View introduction.' })

    delete settings_email_template_reset_path(AccountConfig::SUBMITTER_VIEW_INVITATION_EMAIL_KEY)

    expect(account.account_configs.find_by(key: AccountConfig::SUBMITTER_VIEW_INVITATION_EMAIL_KEY)).to be_nil
  end

  describe 'template preferences' do
    let(:template) { create(:template, account:, author: user, submitter_count: 2) }

    it 'saves template parts over the account version and resets to it' do
      create(:account_config, account:, key: invitation_key, value: { 'heading' => 'Account heading' })
      template.update!(preferences: { 'request_email_subject' => 'Legacy', 'request_email_body' => 'Legacy body' })

      effective = Stevensed::EmailParts.effective_fields(invitation_key, account:, scope: :account)
      second_uuid = template.submitters.last['uuid']

      post template_preferences_path(template), params: {
        email_key: invitation_key,
        email_parts: effective.merge('intro' => 'Template introduction.'),
        email_parts_by_submitter: { second_uuid => { 'closing' => 'Second party closing.', 'heading' => '' } }
      }

      template.reload

      expect(template.preferences['email_parts']).to eq(invitation_key => { 'intro' => 'Template introduction.' })
      expect(template.preferences['email_parts_by_submitter'])
        .to eq(second_uuid => { 'closing' => 'Second party closing.' })
      expect(template.preferences).not_to have_key('request_email_body')

      delete template_preferences_path(template), params: { config_key: invitation_key }

      template.reload

      expect(template.preferences).not_to have_key('email_parts')
      expect(template.preferences).not_to have_key('email_parts_by_submitter')
    end

    it 'shows the template editor prefilled from the account version' do
      create(:account_config, account:, key: invitation_key, value: { 'intro' => 'Account introduction.' })

      get template_preferences_path(template)

      expect(response.body).to include('Account introduction.')
      expect(response.body).to include('Using the account version.')
    end
  end

  describe 'preview and test send' do
    let(:parts) { { 'heading' => 'Preview heading for {submitter.name}', 'intro' => 'Unsaved **introduction**.' } }

    it 'renders the real branded email with the unsaved text and stores nothing' do
      expect do
        post settings_email_template_preview_path(invitation_key), params: { parts:, variant: 'sign' }
      end.not_to change(Submission, :count)

      html = response.parsed_body['html']

      expect(html).to include('Preview heading for Jordan Rivera')
      expect(html).to include('Unsaved <strong>introduction</strong>.')
      expect(html).to include('Requested by')
      expect(html).to include('Review and sign')
      expect(html).to include('Please read the entire document before signing.')
      sample = I18n.t('stevensed.email_templates.sample_document')

      expect(response.parsed_body['subject']).to eq("StevensED: please review and sign \"#{sample}\"")
    end

    it 'refuses a test when email delivery is not set up' do
      allow(Accounts).to receive(:can_send_emails?).and_return(false)

      expect do
        post settings_email_template_test_path(invitation_key), params: { parts:, variant: 'submit' }
      end.not_to change(ActionMailer::Base.deliveries, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body['error']).to include('Email is not set up')
    end

    it 'sends the test only to the signed-in user' do
      allow(Accounts).to receive(:can_send_emails?).and_return(true)
      ActionMailer::Base.deliveries.clear

      expect do
        post settings_email_template_test_path(invitation_key), params: { parts:, variant: 'submit' }
      end.to change(ActionMailer::Base.deliveries, :count).by(1).and(not_change(Submission, :count))
        .and(not_change(EmailEvent, :count))

      mail = ActionMailer::Base.deliveries.last

      expect(response).to have_http_status(:ok)
      expect(mail.to).to eq(['staff.member@example.org'])
      expect(mail.cc).to be_blank
      expect(mail.bcc).to be_blank
      expect(mail.subject).to start_with('[Test] StevensED: please complete')
      expect(mail.html_part.body.decoded).to include('Review and complete')
    end

    it 'previews completion and copy emails' do
      [AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY, AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY,
       AccountConfig::SUBMITTER_VIEW_INVITATION_EMAIL_KEY,
       AccountConfig::SUBMITTER_INVITATION_REMINDER_EMAIL_KEY].each do |key|
        post settings_email_template_preview_path(key), params: { parts: { 'closing' => 'Closing for preview.' } }

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body['html']).to include('Closing for preview.')
      end
    end

    it 'previews a template email over the account version' do
      template = create(:template, account:, author: user, name: 'Housing agreement')
      create(:account_config, account:, key: invitation_key, value: { 'closing' => 'Account closing.' })

      post settings_email_template_preview_path(invitation_key, template_id: template.id),
           params: { parts: { 'intro' => 'Template introduction.' } }

      html = response.parsed_body['html']

      expect(html).to include('Template introduction.')
      expect(html).to include('Account closing.')
      expect(html).to include('Housing agreement')
    end
  end
end
