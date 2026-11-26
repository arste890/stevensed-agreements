# frozen_string_literal: true

describe 'Signing link not found' do
  before { create(:user) } # an instance without users redirects to setup

  it 'shows a page with a contact for an unknown signing link' do
    get '/s/no-such-link', headers: { 'Accept' => 'text/html' }

    expect(response).to have_http_status(:not_found)
    expect(response.media_type).to eq('text/html')
    expect(response.body).to include('This signing link is not available', Stevensed::CONTACT_EMAIL)
  end

  it 'keeps a JSON error for JSON requests' do
    get '/s/no-such-link', headers: { 'Accept' => 'application/json' }

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq('status' => 404)
  end
end
