# frozen_string_literal: true

# StevensED: pages that used to carry DocuSeal upgrade notices must not link to DocuSeal for a non-demo account.
describe 'Upstream upgrade links' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:) }
  let(:upstream_link) { %r{docuseal\.com|console_redirect|/sign_up\?} }

  before do
    allow(Docuseal).to receive(:demo?).and_return(false)

    sign_in(author)
  end

  it 'shows a plain note on the SMS settings page' do
    get settings_sms_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Not available in StevensED Agreements.')
    expect(response.body).not_to match(upstream_link)
  end

  it 'does not link to DocuSeal from the send dialog' do
    get new_template_submission_path(template)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to match(upstream_link)
  end

  it 'points the API and embedding dialog to the StevensED embedding settings' do
    get template_code_modal_path(template)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(settings_embedding_index_path)
    expect(response.body).not_to match(upstream_link)
  end

  it 'does not link to DocuSeal from the template preferences' do
    get template_preferences_path(template)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to match(upstream_link)
  end

  it 'does not offer an SMS upgrade button for a signer with a phone number' do
    submission = create(:submission, :with_submitters, template:, created_by_user: author)
    submission.submitters.first.update!(phone: '+12025550123')

    get submission_path(submission)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to match(upstream_link)
  end
end
