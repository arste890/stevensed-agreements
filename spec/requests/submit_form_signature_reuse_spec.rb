# frozen_string_literal: true

describe 'Signing link signature prefill' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:, email: 'legal@example.org') }
  let(:template) { create(:template, account:, author:, only_field_types: %w[signature]) }
  let(:submission) { create(:submission, template:, created_by_user: author) }
  let(:submitter) do
    create(:submitter, submission:, uuid: template.submitters.first['uuid'], account:, email: 'legal@example.org',
                       name: 'Signature ID Test')
  end

  it 'offers no signature remembered from another envelope or a saved profile, even for the same mailbox' do
    allow(Submitters::FindRememberedSignature).to receive(:call)
    allow(UserConfigs).to receive(:load_signature)

    sign_in(author)
    get submit_form_path(submitter.slug, signed_signature_uuids: { submitter.email => 'signed' })

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('data-prefill-signature=""', 'data-prefill-initials=""',
                                     'data-remember-signature="false"')
    expect(Submitters::FindRememberedSignature).not_to have_received(:call)
    expect(UserConfigs).not_to have_received(:load_signature)
  end
end
