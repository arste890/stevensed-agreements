# frozen_string_literal: true

describe Stevensed::EmailDarkStyles do
  it 'gives Outlook light backgrounds to darken itself and keeps the button navy with white text' do
    expect(described_class::OUTLOOK_RULES['.se-bg']).to include('#FFFFFF')
    expect(described_class::OUTLOOK_RULES.values.join).not_to include('#141A2E')
    expect(described_class::OUTLOOK_RULES['.se-button td.se-button-cell, .se-button a.se-button-link'])
      .to include('background-color:#1F2948', 'color:#FFFFFF')
  end

  it 'matches an element marked by Outlook itself or inside a marked ancestor' do
    selector = described_class.outlook_selector('.se-bg, .se-button a.se-button-link')

    expect(selector.split(', ')).to include('[data-ogsb] .se-bg', '.se-bg[data-ogsb]', '[data-ogsc] .se-bg',
                                            '.se-button a.se-button-link[data-ogsc]')
  end
end
