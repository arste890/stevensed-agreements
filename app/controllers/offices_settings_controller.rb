# frozen_string_literal: true

# StevensED: admin-managed list of offices offered under "Send as" when sending signature requests.
class OfficesSettingsController < ApplicationController
  before_action :load_account_config

  def show
    authorize!(:read, @account_config)
  end

  def create
    authorize!(:manage, @account_config)

    offices = Stevensed::Requesters.normalize_offices(params[:offices])

    if offices.any?
      @account_config.update!(value: offices)
    elsif @account_config.persisted?
      @account_config.destroy!
    end

    redirect_to settings_offices_path, notice: I18n.t('settings_have_been_saved')
  end

  private

  def load_account_config
    @account_config = AccountConfig.find_or_initialize_by(account: current_account, key: Stevensed::Requesters::OFFICES_KEY)
  end
end
