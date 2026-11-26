# frozen_string_literal: true

class SessionsController < Devise::SessionsController
  before_action :configure_permitted_parameters

  layout 'plain', only: %i[new create] # StevensED: branded sign-in page

  skip_before_action :verify_authenticity_token, if: -> { request.xhr? && request.format.json? }

  respond_to :json, only: :create

  around_action :with_browser_locale

  def create
    email = sign_in_params[:email].to_s.downcase

    if Docuseal.multitenant? && !User.exists?(email:)
      Rollbar.warning('Sign in new user') if defined?(Rollbar)

      respond_to do |format|
        format.html do
          redirect_to new_registration_path(sign_up: true, user: sign_in_params.slice(:email)),
                      notice: t('create_a_new_account')
        end
        format.json do
          render json: { sign_up: true, notice: t('create_a_new_account') }, status: :unprocessable_content
        end
      end

      return
    end

    if User.exists?(email:, otp_required_for_login: true) && sign_in_params[:otp_attempt].blank?
      respond_to do |format|
        format.html { render :otp, locals: { resource: User.new(sign_in_params) }, status: :unprocessable_content }
        format.json { render json: { otp_required: true, email_otp: false }, status: :unprocessable_content }
      end

      return
    end

    super
  end

  # StevensED: after signing out here, also end the StevensED SSO session when the user signed in through it.
  def destroy
    id_token = session[:stevensed_id_token]

    super do
      if id_token.present? && Stevensed::Sso.oidc_enabled?
        return redirect_to(Stevensed::Sso.logout_url(id_token), allow_other_host: true, status: :see_other)
      end
    end
  end

  private

  def after_sign_in_path_for(...)
    if params[:redir].present?
      return console_redirect_index_path(redir: params[:redir]) if params[:redir].starts_with?(Docuseal::CONSOLE_URL)

      return params[:redir]
    end

    super
  end

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_in, keys: [:otp_attempt])
  end

  def set_flash_message(key, kind, options = {})
    return if key == :alert && kind == 'already_authenticated'

    super
  end
end
