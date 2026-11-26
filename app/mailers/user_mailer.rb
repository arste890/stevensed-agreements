# frozen_string_literal: true

class UserMailer < ApplicationMailer
  def invitation_email(user, invited_by: nil)
    @current_account = invited_by&.account || user.account
    @user = user
    @token = @user.send(:set_reset_password_token)

    assign_message_metadata('user_invitation', @user)

    I18n.with_locale(@current_account.locale) do
      mail(to: @user.friendly_name,
           subject: I18n.t('stevensed.email.user_invite_subject', product_name: Stevensed::PRODUCT_NAME))
    end
  end
end
