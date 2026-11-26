# frozen_string_literal: true

module Stevensed
  # StevensED: whether a recipient may assign a document to someone else ("delegate").
  # Most specific setting wins: the choice made when the document was sent (submitter preference), then the
  # template's default ("allow" or "don't allow"), then the account-wide setting.
  module Delegation
    TEMPLATE_KEY = 'allow_delegate'

    module_function

    def allowed?(submitter, account_default: nil)
      prefs = submitter.preferences.to_h
      return prefs[TEMPLATE_KEY] == true if prefs.key?(TEMPLATE_KEY)

      template_value = template_default(submitter.submission.template)
      return template_value unless template_value.nil?

      return account_default unless account_default.nil?

      AccountConfig.exists?(account_id: submitter.account_id, key: AccountConfig::ALLOW_TO_DELEGATE_KEY, value: true)
    end

    # true, false, or nil (use the account setting).
    def template_default(template)
      case template&.preferences.to_h[TEMPLATE_KEY].to_s
      when 'true' then true
      when 'false' then false
      end
    end

    # Default for the Send dialog's checkbox.
    def send_default(template, account)
      value = template_default(template)
      return value unless value.nil?

      AccountConfig.exists?(account_id: account.id, key: AccountConfig::ALLOW_TO_DELEGATE_KEY, value: true)
    end
  end
end
