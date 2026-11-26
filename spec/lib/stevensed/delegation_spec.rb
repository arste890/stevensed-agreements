# frozen_string_literal: true

describe Stevensed::Delegation do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]) }
  let(:submission) { create(:submission, template:, created_by_user: author) }
  let(:submitter) { create(:submitter, submission:, uuid: template.submitters.first['uuid'], account:) }

  it 'falls back to the account setting' do
    expect(described_class.allowed?(submitter)).to be(false)

    create(:account_config, account:, key: AccountConfig::ALLOW_TO_DELEGATE_KEY, value: true)

    expect(described_class.allowed?(submitter)).to be(true)
  end

  it 'uses the template default over the account setting' do
    create(:account_config, account:, key: AccountConfig::ALLOW_TO_DELEGATE_KEY, value: true)
    template.update!(preferences: template.preferences.merge('allow_delegate' => 'false'))

    expect(described_class.allowed?(submitter.reload)).to be(false)
    expect(described_class.send_default(template, account)).to be(false)
  end

  it 'uses the choice made when the document was sent over the template and the account' do
    template.update!(preferences: template.preferences.merge('allow_delegate' => 'false'))
    submitter.update!(preferences: submitter.preferences.merge('allow_delegate' => true))

    expect(described_class.allowed?(submitter)).to be(true)
  end

  it 'records the per-send choice from the Send dialog' do
    prefs = Submitters.normalize_preferences(account, author, ActionController::Parameters.new('allow_delegate' => '1'))

    expect(prefs['allow_delegate']).to be(true)
  end
end
