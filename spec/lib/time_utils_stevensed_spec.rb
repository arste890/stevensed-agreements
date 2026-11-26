# frozen_string_literal: true

describe TimeUtils do
  it 'shows date-only fields in the StevensED style, whatever format the field stored' do
    expect(described_class.format_date_string('2026-11-26', 'MM/DD/YYYY', 'en-US')).to eq('26 November 2026')
    expect(described_class.format_date_string('2026-11-26', nil, 'en-US')).to eq('26 November 2026')
    expect(described_class.format_date_string('2026-03-05', 'DD/MM/YYYY', 'en-GB')).to eq('5 March 2026')
  end

  it 'keeps formats with a time or without a day' do
    expect(described_class.stevensed_format('MM/DD/YYYY HH:mm')).to eq('MM/DD/YYYY HH:mm')
    expect(described_class.stevensed_format('MMMM YYYY')).to eq('MMMM YYYY')
  end

  it 'uses the StevensED long date in the English locales' do
    %i[en en-US en-GB].each do |locale|
      expect(I18n.l(Date.new(2026, 11, 26), format: :long, locale:)).to eq('26 November 2026')
    end
  end
end
