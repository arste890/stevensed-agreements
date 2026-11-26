# frozen_string_literal: true

class SsoSettingsController < ApplicationController
  before_action :load_encrypted_config
  authorize_resource :encrypted_config, only: :index

  def index; end

  # StevensED: SAML 2.0 identity provider settings.
  def create
    authorize!(:manage, @encrypted_config)

    attrs = params.require(:saml).permit(:idp_sso_service_url, :idp_cert, :idp_cert_fingerprint, :sp_entity_id)
                  .to_h.transform_values(&:strip).compact_blank

    if attrs.empty?
      @encrypted_config.destroy! if @encrypted_config.persisted?
    else
      unless attrs['idp_sso_service_url'].to_s.start_with?('https://')
        return redirect_to settings_sso_index_path, alert: I18n.t('stevensed.saml_https_required')
      end

      @encrypted_config.update!(value: attrs)
    end

    redirect_to settings_sso_index_path, notice: I18n.t('settings_have_been_saved')
  end

  private

  def load_encrypted_config
    @encrypted_config =
      EncryptedConfig.find_or_initialize_by(account: current_account, key: 'saml_configs')
  end
end
