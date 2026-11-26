# frozen_string_literal: true

# StevensED: copy and paste instructions for embedding the signing form and the template builder.
class EmbeddingSettingsController < ApplicationController
  def index
    authorize!(:manage, AccountConfig)

    @allowed_origins = Stevensed::Embed.allowed_origins
    @snippets = Stevensed::EmbedSnippets.call(
      app_url: root_url.chomp('/'),
      template: current_account.templates.active.order(id: :desc).first
    )
  end
end
