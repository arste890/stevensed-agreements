# frozen_string_literal: true

describe Submitters::GenerateFontImage do
  it 'renders typed signatures and initials with the self-hosted MonteCarlo font' do
    path = described_class::FONTS.fetch(described_class::FONT_ALIASES.fetch('signature'))

    expect(described_class::FONT_ALIASES.fetch('initials')).to eq('MonteCarlo Regular')
    expect(path).to eq(Rails.public_path.join('fonts/MonteCarlo-Regular.ttf').to_s)
    expect(File.binread(path, 4)).to eq("\x00\x01\x00\x00".b)
    expect(Rails.public_path.join('fonts/OFL-MonteCarlo.txt').read).to include('SIL Open Font License')
  end

  it 'returns a PNG of the typed text' do
    data, width, height = described_class.call('Alexandria Montgomery-Fitzwilliam', font: 'signature')

    expect(data.b).to start_with("\x89PNG".b)
    expect(width).to be > height
    expect(height).to be_between(1, described_class::HEIGHT)
  end
end
