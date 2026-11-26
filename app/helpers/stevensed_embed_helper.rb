# frozen_string_literal: true

# StevensED: meta tag read by the embed bridge (/js/frame.js) inside embedded pages.
module StevensedEmbedHelper
  DOWNLOAD_LINK_TTL = 40.minutes

  def stevensed_embed_meta_tag(submitter: nil, template: nil)
    state = content_for(:stevensed_embed_state).presence || 'page'

    data = { allowed_origins: Stevensed::Embed.allowed_origins.to_json, state: }

    if submitter.is_a?(Submitter) && submitter.persisted?
      data[:submitter_id] = submitter.id
      data[:submitter_slug] = submitter.slug

      if state.in?(%w[form completed])
        data[:download_url] = submit_form_documents_url(
          submitter.slug,
          sig: submitter.signed_id(purpose: :download_completed, expires_in: DOWNLOAD_LINK_TTL)
        )
      end
    end

    data[:template_id] = template.id if template.is_a?(Template) && template.persisted?

    tag.meta(name: 'stevensed-embed', data:)
  end
end
