# frozen_string_literal: true

# StevensED: creates a template from pasted HTML with field tags (admin and editor roles).
class TemplatesHtmlController < ApplicationController
  def new
    authorize!(:create, Template.new(account: current_account, author: current_user))
  end

  def create
    authorize!(:create, Template.new(account: current_account, author: current_user))

    template = Stevensed::HtmlTemplates.call(
      account: current_account,
      author: current_user,
      html: params[:html],
      html_header: params[:html_header].presence,
      html_footer: params[:html_footer].presence,
      name: params[:name],
      size: params[:size],
      folder_name: params[:folder_name]
    )

    SearchEntries.enqueue_reindex(template)

    WebhookUrls.enqueue_events(template, 'template.created')

    redirect_to edit_template_path(template)
  rescue Stevensed::HtmlTemplates::Error => e
    @error_message = e.message

    render turbo_stream: turbo_stream.replace(:modal, template: 'templates_html/new'), status: :unprocessable_content
  end
end
