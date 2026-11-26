# frozen_string_literal: true

# StevensED: resolves the user of an embedded template builder session (see Stevensed::EmbedBuilder).
# The embedded user is returned only for the builder page and the builder requests listed in
# Stevensed::EmbedBuilder::ALLOWED_REQUESTS, and only for the template named in the token.
# A regular signed in session always takes precedence.
module StevensedEmbedBuilderAuthentication
  def current_user
    super || stevensed_embed_builder_user
  end

  def authenticate_user!(*)
    return if stevensed_embed_builder_user && !warden.authenticated?(:user)

    super
  end

  private

  def stevensed_embed_builder_user
    return @stevensed_embed_builder_user if defined?(@stevensed_embed_builder_user)

    @stevensed_embed_builder_user =
      if Stevensed::EmbedBuilder.allowed_request?(session, controller_path:, action: action_name,
                                                           template_id: stevensed_embed_template_param)
        Stevensed::EmbedBuilder.session_user(session)
      end
  end

  def stevensed_embed_template_param
    controller_path == 'templates' ? params[:id] : params[:template_id]
  end
end
