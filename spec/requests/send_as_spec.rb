# frozen_string_literal: true

describe 'Send as' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:, first_name: 'Alec', last_name: 'Stevens') }

  before { sign_in(user) }

  def update_profile(office)
    patch update_contact_settings_profile_index_path,
          params: { user: { first_name: user.first_name, last_name: user.last_name, email: user.email }, office: }
  end

  it 'saves the office list from settings' do
    offices = "Office of the Bursar\n\n  Office of the Registrar \nOffice of the Bursar"

    post settings_offices_path, params: { offices: }

    expect(Stevensed::Requesters.offices(account)).to eq(['Office of the Bursar', 'Office of the Registrar'])

    get settings_offices_path

    expect(response.body).to include('Office of the Registrar')
  end

  it 'saves a default office only when it is in the list' do
    update_profile('StevensED Administration')

    expect(Stevensed::Requesters.profile_office(user)).to eq('StevensED Administration')

    update_profile('Unlisted Office')

    expect(user.user_configs.find_by(key: UserConfig::OFFICE_KEY)).to be_nil
  end

  it 'offers Send as in the send dialog and stores the choice on the submission' do
    template = create(:template, account:, author: user)

    get new_template_submission_path(template)

    expect(response.body).to include('Send as')
    expect(response.body).to include('StevensED Administration')

    post template_submissions_path(template),
         params: { emails: 'recipient@example.com', send_email: '1', send_as: 'office|StevensED Administration' }

    expect(template.submissions.last.preferences['requester']).to eq('office' => 'StevensED Administration')
  end
end
