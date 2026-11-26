# frozen_string_literal: true

class SettingsMailer < ApplicationMailer
  def smtp_successful_setup(email)
    mail(to: email, from: email, subject: I18n.t('stevensed.email.smtp_subject', product_name: Stevensed::PRODUCT_NAME))
  end
end
