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

  describe 'when a newer form version has replaced the template' do
    before { template.update!(archived_at: Time.current) }

    it 'opens the completed page for a signer who already signed' do
      submitter.update!(completed_at: 2.days.ago)

      get submit_form_path(submitter.slug)
      expect(response).to redirect_to(submit_form_completed_path(submitter.slug))

      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Form has been deleted')
    end

    it 'still locks the link for a signer who has not signed' do
      get submit_form_path(submitter.slug)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Form has been deleted')
    end

    it 'still locks a completed record that staff archived' do
      submitter.update!(completed_at: 2.days.ago)
      submission.update!(archived_at: Time.current)

      get submit_form_path(submitter.slug)

      expect(response.body).to include('Form has been deleted')
    end
  end
end
