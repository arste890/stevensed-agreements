# frozen_string_literal: true

describe Stevensed::Requesters do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:, first_name: 'Alec', last_name: 'Stevens') }

  before do
    create(:account_config, account:, key: described_class::OFFICES_KEY,
                            value: ['StevensED Administration', 'Office of the Bursar'])
  end

  it 'builds name, name and office, and office-only requesters' do
    expect(described_class.build(user, 'name|')).to eq('name' => 'Alec Stevens')
    expect(described_class.build(user, 'name|Office of the Bursar'))
      .to eq('name' => 'Alec Stevens', 'office' => 'Office of the Bursar')
    expect(described_class.build(user, 'office|Office of the Bursar')).to eq('office' => 'Office of the Bursar')
  end

  it 'rejects offices that are not in the admin list' do
    expect(described_class.build(user, 'office|Office of Something Else')).to be_nil
    expect(described_class.build(user, 'office|')).to be_nil
  end

  it 'formats labels and From names' do
    expect(described_class.label('name' => 'Alec Stevens')).to eq('Alec Stevens, StevensED')
    expect(described_class.from_name('office' => 'Office of the Bursar')).to eq('Office of the Bursar, StevensED')
    expect(described_class.from_name('office' => 'StevensED Administration')).to eq('StevensED Administration')
    expect(described_class.from_address('office' => 'Office of the Bursar'))
      .to eq('"Office of the Bursar, StevensED" <legal@stevensed.org>')
  end

  it 'labels the consent step in sentence case, by office when one is set' do
    expect(described_class.from_label('name' => 'StevensED Admin')).to eq('From StevensED')
    expect(described_class.from_label('name' => 'Alec Stevens', 'office' => 'Office of the Bursar'))
      .to eq('From Office of the Bursar')
  end
end
