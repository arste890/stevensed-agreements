# frozen_string_literal: true

describe Stevensed::Downloads do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]) }
  let(:submission) { create(:submission, template:, created_by_user: author) }

  it 'offers documents only until everyone has signed' do
    expect(described_class.kinds(submission)).to eq(%w[documents])
    expect(described_class.default_kind(submission)).to eq('documents')
    expect(described_class.resolve(submission, 'audit')).to be_nil
    expect(described_class.resolve(submission, 'combined')).to eq('documents')
  end

  it 'gives signers the completed document and staff the combined PDF, with all three in the menu' do
    submission.update!(completed_at: Time.current)

    expect(described_class.kinds(submission)).to eq(%w[documents audit combined])
    expect(described_class.default_kind(submission)).to eq('documents')
    expect(described_class.default_kind(submission, audience: :staff)).to eq('combined')
    expect(described_class.resolve(submission, nil)).to eq('documents')
    expect(described_class.resolve(submission, nil, audience: :staff)).to eq('combined')
    expect(described_class.resolve(submission, 'audit')).to eq('audit')
    expect(described_class.kinds(submission).map { |k| described_class.label(k) })
      .to eq(['Completed document', 'Audit log', 'Combined (document and audit log)'])
  end

  it 'gives staff the completed document when the account turns combining off' do
    submission.update!(completed_at: Time.current)
    create(:account_config, account:, key: AccountConfig::COMBINE_PDF_RESULT_KEY, value: false)

    expect(described_class.default_kind(submission, audience: :staff)).to eq('documents')
    expect(described_class.kinds(submission)).to include('combined')
  end

  it 'never offers combined for an envelope with an identity-verification field' do
    fields = submission.template_fields + [{ 'uuid' => SecureRandom.uuid, 'type' => 'verification', 'areas' => [],
                                             'submitter_uuid' => template.submitters.first['uuid'] }]
    submission.update!(completed_at: Time.current, template_fields: fields)

    expect(described_class.kinds(submission)).to eq(%w[documents audit])
    expect(described_class.default_kind(submission, audience: :staff)).to eq('documents')
  end
end
