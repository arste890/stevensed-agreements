# frozen_string_literal: true

# StevensED: company logo shown on signing pages, the dashboard and the audit trail.
class AccountLogosController < ApplicationController
  ALLOWED_TYPES = %w[image/png image/jpeg image/webp].freeze
  MAX_SIZE = 2.megabytes

  skip_before_action :authenticate_user!, only: :show
  skip_authorization_check only: :show

  def show
    account = Account.find_by!(uuid: params[:uuid])

    raise ActiveRecord::RecordNotFound unless account.logo.attached?

    expires_in 1.hour, public: true
    send_data account.logo.download, type: account.logo.content_type, disposition: 'inline'
  end

  def create
    authorize!(:manage, current_account)

    file = params.require(:logo)

    if ALLOWED_TYPES.exclude?(Marcel::MimeType.for(file)) || file.size > MAX_SIZE
      return redirect_to settings_personalization_path, alert: I18n.t('stevensed.logo_invalid')
    end

    current_account.logo.attach(io: file, filename: file.original_filename.presence || 'logo',
                                content_type: Marcel::MimeType.for(file))

    redirect_to settings_personalization_path, notice: I18n.t('settings_have_been_saved')
  end

  def destroy
    authorize!(:manage, current_account)

    current_account.logo.purge

    redirect_to settings_personalization_path, notice: I18n.t('settings_have_been_saved')
  end
end
