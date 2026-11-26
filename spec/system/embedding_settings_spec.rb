# frozen_string_literal: true

RSpec.describe 'Embedding settings' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account:) }

  it 'shows the embed snippets to admins' do
    create(:template, account:, author: admin, only_field_types: %w[text])

    sign_in(admin)
    visit settings_embedding_index_path

    expect(page).to have_content('Embedding')
    expect(page).to have_content('https://*.stevensed.org')
    expect(page).to have_content('stevensed-form')
    expect(page).to have_content('stevensed-builder')
    expect(page).to have_content('/api/templates/html')
    expect(page).to have_no_content('DocuSeal')
  end

  it 'is not available to editors' do
    editor = create(:user, account:, role: User::EDITOR_ROLE)

    sign_in(editor)
    visit settings_embedding_index_path

    expect(page).to have_no_content('Allowed sites')
  end

  it 'opens the HTML template form from the create dialog' do
    sign_in(admin)
    visit new_template_path

    click_link 'Create a template from HTML'

    expect(page).to have_field('html')
    expect(page).to have_select('size', selected: 'Letter')
  end
end
