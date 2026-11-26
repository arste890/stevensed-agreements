# frozen_string_literal: true

describe 'Signing link completion page' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]) }
  let(:submission) { create(:submission, template:, created_by_user: author) }
  let(:submitter) { create(:submitter, submission:, uuid: template.submitters.first['uuid'], account:) }

  it 'sends a signer who has not finished back to the form instead of failing' do
    get submit_form_completed_path(submitter.slug)

    expect(response).to redirect_to(submit_form_path(submitter.slug))
  end
end
