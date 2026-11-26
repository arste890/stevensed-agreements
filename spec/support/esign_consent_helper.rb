# frozen_string_literal: true

# StevensED: accept the electronic records and signature consent shown before signing.
module EsignConsentHelper
  def accept_esign_consent
    within('esign-consent') do
      check 'I agree to use electronic records and signatures.'
      click_button 'Continue'
    end

    expect(page).to have_no_css('esign-consent')
  end
end

RSpec.configure do |config|
  config.include EsignConsentHelper, type: :system
end
