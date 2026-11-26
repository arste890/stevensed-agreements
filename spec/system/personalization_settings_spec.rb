# frozen_string_literal: true

RSpec.describe 'Personalization Settings', :js do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  before do
    sign_in(user)
    visit settings_personalization_path
  end

  it 'shows the notifications settings page' do
    expect(page).to have_content('Email templates')
    expect(page).to have_content('Company logo')
    expect(page).to have_content('Submission form')
  end
end
