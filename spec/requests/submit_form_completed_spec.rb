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

  describe 'downloads after the first 30 minutes' do
    before { submitter.update!(completed_at: 2.days.ago, email: 'parent@example.com') }

    def download_menu?
      response.body.include?(submit_form_documents_path(submitter.slug, kind: 'documents'))
    end

    it 'shows the downloads to the parent signed in with the signer email' do
      sign_in(create(:user, account:, role: User::CLIENT_ROLE, email: 'parent@example.com'))

      get submit_form_completed_path(submitter.slug)

      expect(response).to have_http_status(:ok)
      expect(download_menu?).to be(true)
    end

    it 'hides them from another signed-in parent' do
      sign_in(create(:user, account:, role: User::CLIENT_ROLE, email: 'someone.else@example.com'))

      get submit_form_completed_path(submitter.slug)

      expect(download_menu?).to be(false)
    end

    it 'offers the StevensED sign-in to a signer who is not signed in' do
      get submit_form_completed_path(submitter.slug)

      expect(download_menu?).to be(false)
      expect(response.body).to include('Sign in with your StevensED account to download your copy')
    end
  end
end
