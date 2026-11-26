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
end
