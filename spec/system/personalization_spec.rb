# frozen_string_literal: true

RSpec.describe 'Personalization' do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  before do
    sign_in(user)
    visit settings_personalization_path
  end

  it 'shows the personalization page' do
    expect(page).to have_content('Email templates')
    expect(page).to have_content('Signature request email')
    expect(page).to have_content('Completed notification email')
    expect(page).to have_content('Documents copy email')
    expect(page).to have_content('Company logo')
  end
end
