# frozen_string_literal: true

describe SubmitterMailer do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:, first_name: 'Morgan', last_name: 'Hale') }
  let(:template) { create(:template, account:, author: user) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: user) }
  let(:submitter) { submission.submitters.first }

  def deliver_invitation
    described_class.invitation_email(submitter).deliver_now

    ActionMailer::Base.deliveries.last
  end

  it 'sends a branded, ASCII-only signature request' do
    mail = deliver_invitation
    html = mail.html_part.body.decoded

    expect(mail.subject).to start_with('StevensED')
    expect(mail.reply_to).to eq([Stevensed::CONTACT_EMAIL])
    expect(html).to include('This link is personal to you.')
    expect(html).to include('Confidential.')
    expect(html).to match(/SA-\d{4}-\d{5,}/)
    expect(html).to be_ascii_only
    expect(mail.html_part.content_transfer_encoding).to eq('7bit')
  end

  it 'shows the sender and organization when no requester was chosen' do
    mail = deliver_invitation

    expect(mail.html_part.body.decoded).to include("Morgan Hale<br>#{Stevensed::ORGANIZATION}")
    expect(mail.from).to eq([Stevensed::CONTACT_EMAIL])
    expect(mail[:from].display_names.first).to eq("Morgan Hale, #{Stevensed::ORGANIZATION}")
  end

  it 'uses the office chosen under Send as for Requested by and the From name' do
    create(:account_config, account:, key: Stevensed::Requesters::OFFICES_KEY, value: ['Office of the Bursar'])
    submission.update!(preferences: submission.preferences.merge('requester' => { 'office' => 'Office of the Bursar' }))

    mail = deliver_invitation

    expect(mail.html_part.body.decoded).not_to include('Morgan Hale')
    expect(mail.text_part.body.decoded).to include('Office of the Bursar')
    expect(mail[:from].display_names.first).to eq("Office of the Bursar, #{Stevensed::ORGANIZATION}")
  end

  it 'keeps the reset link as the first link in the password reset email' do
    Devise::Mailer.reset_password_instructions(user, 'reset-token').deliver_now
    mail = ActionMailer::Base.deliveries.last

    expect(mail.body.encoded[/href="([^"]+)"/, 1]).to include('reset_password_token=reset-token')
    expect(mail.subject).to eq('StevensED Agreements: password reset instructions')
  end

  describe 'completed notice to the sender' do
    before do
      template.update!(preferences: template.preferences.merge('completed_notification_email_attach_documents' => false,
                                                               'completed_notification_email_attach_audit' => false))
      submitter.update!(completed_at: Time.current)
    end

    it 'greets the sending user by full name and draws a bulletproof button with a dark palette' do
      html = described_class.completed_email(submitter, user).deliver_now.html_part.body.decoded

      expect(html).to include('Dear Morgan Hale,')
      expect(html).to include('class="se-button-cell" align="center" bgcolor="#1F2948"', 'v:roundrect')
      expect(html).to match(/class="se-button-link"[^>]+padding:13px 30px/)
      expect(html).not_to include('border-top:13px solid')
      expect(html).to include('@media (prefers-color-scheme: dark)', '[data-ogsb] .se-bg', '[data-ogsc] .se-label-cell')
      expect(html).to be_ascii_only
    end

    it 'uses a neutral greeting when the only name is the organization' do
      user.update!(first_name: Stevensed::ORGANIZATION, last_name: nil)

      html = described_class.completed_email(submitter, user).deliver_now.html_part.body.decoded

      expect(html).to include('<p>Hello,</p>')
      expect(html).not_to include("Dear #{Stevensed::ORGANIZATION},")
    end
  end
end
