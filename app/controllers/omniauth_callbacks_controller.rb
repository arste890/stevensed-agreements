# frozen_string_literal: true

# StevensED: single sign-on callback for OpenID Connect (provider "stevensed") and SAML.
class OmniauthCallbacksController < ApplicationController
  skip_before_action :authenticate_user!
  skip_before_action :verify_authenticity_token, only: %i[callback]
  skip_authorization_check

  def callback
    user = Stevensed::Sso.find_or_create_user(request.env['omniauth.auth'])

    sign_in(:user, user)

    redirect_to user.role == User::CLIENT_ROLE ? my_agreements_path : root_path
  rescue Stevensed::Sso::Error => e
    redirect_to new_user_session_path(local: 1), alert: e.message
  end

  def failure
    redirect_to new_user_session_path(local: 1), alert: I18n.t('stevensed.sso_failed')
  end
end
