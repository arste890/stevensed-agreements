# frozen_string_literal: true

RSpec.describe 'Personalization' do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  before do
    sign_in(user)
    visit settings_personalization_path
  end

  it 'shows the personalization page' do
    expect(page).to have_content('Email Templates')
    expect(page).to have_content('Signature request')
    expect(page).to have_content('View-only invitation')
    expect(page).to have_content('Reminder')
    expect(page).to have_content('Completion notice to the sender')
    expect(page).to have_content('Documents copy to the signer')
    expect(page).to have_content('Company Logo')
  end
end
