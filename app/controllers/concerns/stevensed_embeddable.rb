# frozen_string_literal: true

# StevensED: allows a response to be shown in an iframe on the origins listed in EMBED_ALLOWED_ORIGINS.
# Every other response keeps X-Frame-Options SAMEORIGIN and frame-ancestors 'self'.
module StevensedEmbeddable
  extend ActiveSupport::Concern

  included do
    after_action :allow_stevensed_embedding
  end

  private

  def allow_stevensed_embedding
    response.headers.delete('X-Frame-Options')

    policy = request.content_security_policy&.clone || ActionDispatch::ContentSecurityPolicy.new
    policy.frame_ancestors(*Stevensed::Embed.frame_ancestors)

    request.content_security_policy = policy
  end
end
