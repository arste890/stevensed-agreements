# frozen_string_literal: true

describe Stevensed::EmailDarkStyles do
  it 'draws dark backgrounds as gradients, which Outlook ignores, and never as background colours' do
    css = described_class.rules.map { |selector, declarations| "#{selector} { #{declarations} }" }.join("\n")

    expect(css).to include('.se-bg { background-image:linear-gradient(#141A2E, #141A2E) !important; }')
    expect(css).not_to include('background-color')
  end

  it 'keeps the button text white in dark mode' do
    button = described_class.rules.select { |selector, _| selector.include?('se-button-link') }.map(&:last).join

    expect(button).to include('color:#FFFFFF', 'linear-gradient(#34478A')
  end
end
