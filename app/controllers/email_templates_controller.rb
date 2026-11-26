# frozen_string_literal: true

# StevensED: preview, test send and account-level reset for the email template editor
# (Settings > Personalization and Template preferences). See Stevensed::EmailParts.
class EmailTemplatesController < ApplicationController
  TEST_SENDS_PER_WINDOW = 5

  RATE_LIMITED = lambda {
    render json: { error: I18n.t('stevensed.email_templates.test_rate_limited') }, status: :too_many_requests
  }

  rate_limit to: TEST_SENDS_PER_WINDOW, within: 10.minutes, only: :test_email, by: -> { current_user.id },
             with: RATE_LIMITED

  before_action :load_key
  before_action :load_and_authorize_scope, only: %i[preview test_email]

  def preview
    message = build_message

    render json: { subject: message.subject.to_s, html: Stevensed::EmailPreviews.html(message) }
  end

  def test_email
    # StevensED: say so when email delivery is not set up, instead of reporting a test that was never sent.
    unless Accounts.can_send_emails?(current_account)
      return render json: { error: I18n.t('stevensed.email_templates.test_unavailable') },
                    status: :unprocessable_content
    end

    message = build_message

    Stevensed::EmailPreviews.deliver_test(message, current_user)

    render json: { message: I18n.t('stevensed.email_templates.test_sent', email: current_user.email) }
  rescue StandardError => e
    Rollbar.error(e) if defined?(Rollbar)

    raise if Rails.env.test?

    render json: { error: I18n.t('stevensed.email_templates.test_failed') }, status: :unprocessable_content
  end

  # Account level: removes the saved parts (and any legacy free-form body); other settings of the email stay.
  def reset
    config = current_account.account_configs.find_by(key: @key)

    if config
      authorize!(:update, config)

      value = config.value.is_a?(Hash) ? config.value : {}
      value = value.except(*Stevensed::EmailParts::FIELDS, *Stevensed::EmailParts::LEGACY_ACCOUNT_KEYS)

      value.present? ? config.update!(value:) : config.destroy!
    else
      authorize!(:create, current_account.account_configs.new(key: @key))
    end

    redirect_to settings_personalization_path, notice: I18n.t('stevensed.email_templates.reset_done')
  end

  private

  def load_key
    @key = params[:key].to_s

    raise ActionController::RoutingError, 'Not Found' unless Stevensed::EmailParts::KEYS.include?(@key)
  end

  def load_and_authorize_scope
    if params[:template_id].present?
      @template = Template.accessible_by(current_ability).find(params[:template_id])

      authorize!(:update, @template)
    else
      authorize!(:create, current_account.account_configs.new(key: @key))
    end
  end

  def build_message
    Stevensed::EmailPreviews.build(
      key: @key,
      user: current_user,
      parts: params.fetch(:parts, {}).permit(*Stevensed::EmailParts::FIELDS).to_h,
      scope: @template ? 'template' : 'account',
      variant: params[:variant].to_s,
      template: @template
    )
  end
end
