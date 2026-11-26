# frozen_string_literal: true

describe 'Error pages' do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:) }

  # Render errors through ErrorsController, as in production, instead of raising them in the test.
  around do |example|
    env_config = Rails.application.env_config
    original = env_config.slice('action_dispatch.show_exceptions', 'action_dispatch.show_detailed_exceptions')

    env_config['action_dispatch.show_exceptions'] = :all
    env_config['action_dispatch.show_detailed_exceptions'] = false

    example.run
  ensure
    env_config.merge!(original)
  end

  it 'renders a 406 page when the submissions export is requested as HTML' do
    template = create(:template, account:, author:)

    sign_in(author)

    get "/templates/#{template.id}/submissions_export"

    expect(response).to have_http_status(:not_acceptable)
    expect(response.media_type).to eq('text/html')
    expect(response.body).to include('This page is not available in the requested format.')
  end

  it 'renders the HTML 404 page when an unknown path is requested in another format' do
    get '/no-such-page.csv'

    expect(response).to have_http_status(:not_found)
    expect(response.media_type).to eq('text/html')
    expect(response.body).to include("Sorry, we couldn't find this page.")
  end

  it 'has a page for every status ErrorsController can be asked to render' do
    statuses = ActionDispatch::ExceptionWrapper.rescue_responses.values.uniq.map do |status|
      Rack::Utils.status_code(status)
    end

    controller = ErrorsController.new

    statuses.each do |status|
      allow(controller).to receive(:error_status_code).and_return(status)

      page = controller.send(:error_page)

      expect(Rails.root.join("app/views/errors/#{page}.html")).to exist, "no error page for status #{status}"
      expect(page).to eq(status.to_s).or eq(status < 500 ? '400' : '500')
    end
  end

  it 'does not redirect signed-in users to the upstream console' do
    sign_in(author)

    get '/upgrade'

    expect(response).to have_http_status(:not_found)
  end

  describe 'web app manifest' do
    it 'serves /manifest.json' do
      get '/manifest.json'

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['name']).to eq(Docuseal.product_name)
    end

    it 'redirects /manifest to /manifest.json' do
      get '/manifest'

      expect(response).to redirect_to('/manifest.json')
    end
  end
end
