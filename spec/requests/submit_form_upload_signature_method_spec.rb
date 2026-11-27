# frozen_string_literal: true

describe 'Signature upload' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: author) }
  let(:submitter) { submission.submitters.first }

  it 'records how the signature was adopted' do
    post "/s/#{submitter.slug}/upload", params: {
      file: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-image.png'), 'image/png'),
      type: 'signature', name: 'attachments', signature_method: 'drawn'
    }

    expect(response).to have_http_status(:ok)
    expect(submitter.attachments.last.metadata['signature_method']).to eq('drawn')
  end

  it 'ignores an unknown method' do
    post "/s/#{submitter.slug}/upload", params: {
      file: Rack::Test::UploadedFile.new(Rails.root.join('spec/fixtures/sample-image.png'), 'image/png'),
      type: 'signature', name: 'attachments', signature_method: 'forged'
    }

    expect(submitter.attachments.last.metadata).not_to have_key('signature_method')
  end
end
