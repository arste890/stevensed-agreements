# frozen_string_literal: true

module Api
  # StevensED: POST /api/templates/html creates a template from HTML with field tags.
  # See Stevensed::HtmlTemplates and docs/STEVENSED_EMBEDDING_AND_HTML.md.
  class TemplatesHtmlController < ApiBaseController
    def create
      authorize!(:create, Template.new(account: current_account, author: current_user))

      template = Stevensed::HtmlTemplates.call(
        account: current_account,
        author: current_user,
        html: params[:html],
        html_header: params[:html_header],
        html_footer: params[:html_footer],
        name: params[:name],
        size: params[:size],
        folder_name: params[:folder_name],
        external_id: params[:external_id],
        source: 'api'
      )

      SearchEntries.enqueue_reindex(template)

      WebhookUrls.enqueue_events(template, 'template.created')

      render json: Templates::SerializeForApi.call(template.reload)
    rescue Stevensed::HtmlTemplates::Error => e
      render json: { error: e.message }, status: :unprocessable_content
    end
  end
end
