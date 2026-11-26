# frozen_string_literal: true

describe 'Embedding' do
  let(:account) { create(:account) }
  let!(:author) { create(:user, account:) }
  let(:template) { create(:template, account:, author:, only_field_types: %w[text]) }

  def builder_token(user:, payload: {}, key: user.access_token.token)
    JWT.encode({ user_email: user.email, template_id: template.id, iat: Time.now.to_i,
                 exp: 15.minutes.from_now.to_i }.merge(payload), key, 'HS256')
  end

  describe 'GET /js/:filename' do
    it 'serves the signing form script' do
      get '/js/form.js'

      expect(response).to have_http_status(:ok)
      expect(response.headers['Content-Type']).to include('application/javascript')
      expect(response.body).to include("customElements.define('stevensed-form'")
      expect(response.body).to include("customElements.define('docuseal-form'")
      expect(response.body).not_to include('Upgrade to Pro')
    end

    it 'serves the builder script and the frame bridge' do
      get '/js/builder.js'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("customElements.define('stevensed-builder'")
      expect(response.body).to include("customElements.define('docuseal-builder'")

      get '/js/frame.js'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('stevensed:hello')
    end

    it 'returns not found for other files' do
      get '/js/other.js'

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'frame-ancestors' do
    let(:submission) { create(:submission, :with_submitters, template:) }
    let(:submitter) { submission.submitters.first }

    it 'allows the signing form on StevensED sites' do
      get submit_form_path(slug: submitter.slug)

      expect(response).to have_http_status(:ok)
      expect(response.headers['X-Frame-Options']).to be_nil
      expect(response.headers['Content-Security-Policy'])
        .to include("frame-ancestors 'self' https://stevensed.org https://*.stevensed.org")
      expect(response.body).to include('name="stevensed-embed"')
      expect(response.body).to include('/js/frame.js')
    end

    it 'uses the origins from EMBED_ALLOWED_ORIGINS' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('EMBED_ALLOWED_ORIGINS', anything)
                                   .and_return('https://praxis.stevensed.org, javascript:alert(1)')

      get submit_form_path(slug: submitter.slug)

      expect(response.headers['Content-Security-Policy']).to include("frame-ancestors 'self' https://praxis.stevensed.org")
      expect(response.headers['Content-Security-Policy']).not_to include('javascript')
    end

    it 'keeps other pages limited to the same origin' do
      sign_in(author)

      get settings_profile_index_path

      expect(response).to have_http_status(:ok)
      expect(response.headers['X-Frame-Options']).to eq('SAMEORIGIN')
      expect(response.headers['Content-Security-Policy']).to include("frame-ancestors 'self'")
      expect(response.headers['Content-Security-Policy']).not_to include('stevensed.org')
    end
  end

  describe 'embedded builder' do
    it 'opens the builder for a valid token' do
      post embed_builder_path, params: { token: builder_token(user: author) }

      expect(response).to redirect_to(embed_builder_path)
      expect(response).to have_http_status(:see_other)

      get embed_builder_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<template-builder')
      expect(response.body).to include('data-embedded="true"')
      expect(response.headers['X-Frame-Options']).to be_nil
      expect(response.headers['Content-Security-Policy']).to include('frame-ancestors')
      expect(response.headers['Content-Security-Policy']).to include('https://*.stevensed.org')
    end

    it 'finds the template by external id' do
      template.update!(external_id: 'enrollment-2026')

      post embed_builder_path, params: { token: builder_token(user: author,
                                                              payload: { template_id: nil,
                                                                         external_id: 'enrollment-2026' }) }

      expect(response).to redirect_to(embed_builder_path)
    end

    it 'rejects an expired token' do
      token = builder_token(user: author, payload: { iat: 2.hours.ago.to_i, exp: 1.hour.ago.to_i })

      post embed_builder_path, params: { token: }

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to include(I18n.t('stevensed.embed.invalid_token'))
    end

    it 'rejects a token that lives longer than one hour' do
      post embed_builder_path, params: { token: builder_token(user: author, payload: { exp: 3.hours.from_now.to_i }) }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a token signed with the API token of another user' do
      other_user = create(:user, account:)

      post embed_builder_path, params: { token: builder_token(user: author, key: other_user.access_token.token) }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects a token for a template in another account' do
      other_account = create(:account)
      other_template = create(:template, account: other_account, author: create(:user, account: other_account),
                                         only_field_types: %w[text])

      post embed_builder_path, params: { token: builder_token(user: author,
                                                              payload: { template_id: other_template.id }) }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'rejects users without the admin or editor role' do
      viewer = create(:user, account:, role: User::VIEWER_ROLE)

      post embed_builder_path, params: { token: builder_token(user: viewer) }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'accepts the editor role' do
      editor = create(:user, account:, role: User::EDITOR_ROLE)

      post embed_builder_path, params: { token: builder_token(user: editor) }

      expect(response).to redirect_to(embed_builder_path)
    end

    it 'rejects tokens that are not HS256' do
      token = JWT.encode({ user_email: author.email, template_id: template.id, exp: 5.minutes.from_now.to_i },
                         nil, 'none')

      post embed_builder_path, params: { token: }

      expect(response).to have_http_status(:unauthorized)
    end

    it 'shows an error without a builder session' do
      get embed_builder_path

      expect(response).to have_http_status(:unauthorized)
    end

    it 'limits the session to builder requests for the token template' do
      other_template = create(:template, account:, author:, only_field_types: %w[text])

      post embed_builder_path, params: { token: builder_token(user: author) }

      put template_path(template), params: { template: { name: 'Renamed in builder' } }, as: :json

      expect(response).to have_http_status(:ok)
      expect(template.reload.name).to eq('Renamed in builder')

      put template_path(other_template), params: { template: { name: 'Not allowed' } }, as: :json

      expect(other_template.reload.name).not_to eq('Not allowed')

      get template_path(template)

      expect(response).not_to have_http_status(:ok)

      get settings_profile_index_path

      expect(response).not_to have_http_status(:ok)
    end

    it 'ends the session when the token expires' do
      token = builder_token(user: author, payload: { exp: 10.minutes.from_now.to_i })

      post embed_builder_path, params: { token: }

      travel_to(11.minutes.from_now) do
        get embed_builder_path

        expect(response).to have_http_status(:unauthorized)
      end
    end
  end
end
