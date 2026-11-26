# frozen_string_literal: true

module Stevensed
  # StevensED: authorization for the embedded template builder.
  #
  # A StevensED server mints a short lived HS256 JSON Web Token signed with the API token of the user who
  # will edit the template (Settings, API). The token carries:
  #
  #   user_email   email address of that user (admin or editor role)
  #   template_id  numeric template id, or external_id with the template external id
  #   exp          expiry as a Unix timestamp, at most one hour in the future
  #   iat          optional issue time; when present, exp minus iat may not exceed one hour
  #
  # A valid token opens a builder session that is scoped to one user and one template. The session is kept
  # under its own key, so it does not sign the user in to the rest of the application.
  module EmbedBuilder
    InvalidToken = Class.new(StandardError)

    MAX_TTL = 1.hour
    CLOCK_SKEW = 30.seconds
    MAX_TOKEN_SIZE = 4096
    SESSION_KEY = 'stevensed_embed_builder'
    ROLES = [User::ADMIN_ROLE, User::EDITOR_ROLE].freeze

    # Builder requests that an embedded session may make, by controller path and action.
    ALLOWED_REQUESTS = {
      'templates' => %w[update],
      'template_documents' => %w[index create],
      'template_documents_modify' => %w[create],
      'template_documents_crop' => %w[index create],
      'template_documents_page_objects' => %w[index],
      'templates_versions' => %w[index show create],
      'templates_detect_fields' => %w[create]
    }.freeze

    Result = Struct.new(:user, :template, :expires_at)

    module_function

    def verify_token(token)
      token = token.to_s

      raise InvalidToken, 'Token is missing' if token.blank?
      raise InvalidToken, 'Token is too long' if token.bytesize > MAX_TOKEN_SIZE

      unverified_payload, header = JWT.decode(token, nil, false)

      raise InvalidToken, 'Unsupported algorithm' unless header['alg'] == 'HS256'

      user = find_user(unverified_payload['user_email'])

      payload, = JWT.decode(token, user.access_token.token, true,
                            algorithm: 'HS256', required_claims: ['exp'], verify_expiration: true)

      expires_at = validate_lifetime!(payload)

      Result.new(user, find_template(user, payload), expires_at)
    rescue JWT::DecodeError => e
      raise InvalidToken, e.message
    end

    def find_user(email)
      raise InvalidToken, 'user_email is missing' unless email.is_a?(String) && email.present?

      user = User.active.find_by(email: email.strip.downcase)

      raise InvalidToken, 'User not found' if user.nil? || user.access_token.nil?
      raise InvalidToken, 'User role may not edit templates' unless ROLES.include?(user.role)

      user
    end

    def validate_lifetime!(payload)
      now = Time.current.to_i
      exp = Integer(payload['exp'], exception: false)

      raise InvalidToken, 'exp is invalid' unless exp
      raise InvalidToken, 'exp is more than one hour ahead' if exp > now + MAX_TTL.to_i + CLOCK_SKEW.to_i

      if payload.key?('iat')
        iat = Integer(payload['iat'], exception: false)

        raise InvalidToken, 'iat is invalid' if iat.nil? || iat > now + CLOCK_SKEW.to_i
        raise InvalidToken, 'Token lifetime exceeds one hour' if exp - iat > MAX_TTL.to_i
      end

      Time.zone.at(exp)
    end

    def find_template(user, payload)
      templates = Template.where(account_id: user.account_id, archived_at: nil)

      template =
        if payload['template_id'].present?
          templates.find_by(id: Integer(payload['template_id'].to_s, exception: false))
        elsif payload['external_id'].present?
          templates.find_by(external_id: payload['external_id'].to_s)
        end

      raise InvalidToken, 'Template not found' unless template
      raise InvalidToken, 'User may not edit this template' unless Ability.new(user).can?(:update, template)

      template
    end

    def store_session(session, result)
      session[SESSION_KEY] = {
        'user_id' => result.user.id,
        'template_id' => result.template.id,
        'exp' => result.expires_at.to_i
      }
    end

    def load_session(session)
      data = session[SESSION_KEY]

      return unless data.is_a?(Hash)

      if data['exp'].to_i <= Time.current.to_i
        session.delete(SESSION_KEY)

        return
      end

      data
    end

    def session_user(session)
      data = load_session(session)

      return unless data

      user = User.active.find_by(id: data['user_id'])

      user if user && ROLES.include?(user.role)
    end

    def allowed_request?(session, controller_path:, action:, template_id:)
      data = load_session(session)

      return false unless data
      return true if controller_path == 'embed_builder'

      ALLOWED_REQUESTS.fetch(controller_path, []).include?(action.to_s) && template_id.to_s == data['template_id'].to_s
    end
  end
end
