# frozen_string_literal: true

RSpec.describe 'E-signature settings' do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  before do
    sign_in(user)
    visit settings_esign_path
  end

  it 'shows the verify signed PDF section' do
    expect(page).to have_content('E-signature')
    expect(page).to have_content('Upload a signed PDF to check its signatures and certificates.')
    expect(page).to have_content('Verify a signed PDF')
    expect(page).to have_content('Click to upload or drag and drop files')
  end
end
