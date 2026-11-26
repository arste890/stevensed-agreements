# frozen_string_literal: true

# StevensED: template builder for StevensED sites, shown in an iframe by /js/builder.js.
# See Stevensed::EmbedBuilder for the token format and docs/STEVENSED_EMBEDDING_AND_HTML.md for usage.
class EmbedBuilderController < ApplicationController
  include StevensedEmbeddable

  layout 'embed_builder'

  skip_before_action :authenticate_user!
  skip_authorization_check
  skip_forgery_protection only: %i[create]

  def show
    return create if params[:token].present?

    user = stevensed_embed_builder_user

    return render_error(:unauthorized, I18n.t('stevensed.embed.session_expired')) unless user

    if warden.authenticated?(:user) && warden.user(:user).id != user.id
      return render_error(:conflict, I18n.t('stevensed.embed.signed_in_as_another_user'))
    end

    @template = Template.find_by(id: Stevensed::EmbedBuilder.load_session(session)['template_id'])

    return render_error(:not_found, I18n.t('stevensed.embed.session_expired')) unless @template

    authorize!(:update, @template)

    @template_data = Templates.serialize_for_builder(@template)
  end

  def create
    result = Stevensed::EmbedBuilder.verify_token(params[:token])

    Stevensed::EmbedBuilder.store_session(session, result)

    redirect_to embed_builder_path, status: :see_other
  rescue Stevensed::EmbedBuilder::InvalidToken => e
    Rails.logger.info("Embedded builder token rejected: #{e.message}")

    render_error(:unauthorized, I18n.t('stevensed.embed.invalid_token'))
  end

  private

  def render_error(status, message)
    @error_message = message

    render :error, status:
  end
end
