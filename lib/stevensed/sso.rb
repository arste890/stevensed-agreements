# frozen_string_literal: true

module Stevensed
  # StevensED: maps identity provider accounts to users. The identity provider is authoritative for
  # users it created; accounts created locally (for example the break-glass administrator) keep their role.
  module Sso
    CONFIG_KEY = 'stevensed_sso'
    ROLE_MAP = JSON.parse(ENV.fetch('SSO_ROLE_MAP', '{"admin":"admin","staff":"editor","teacher":"editor"}'))
    CLIENT_ROLES = ENV.fetch('SSO_CLIENT_ROLES', 'guardian,parent,client').split(',').map(&:strip)

    Error = Class.new(StandardError)

    module_function

    def oidc_enabled?
      ENV['OIDC_CLIENT_ID'].present?
    end

    def saml_config
      account = Account.order(:id).first
      return unless account

      EncryptedConfig.find_by(account:, key: 'saml_configs')&.value.presence
    end

    def saml_enabled?
      saml_config.present? && saml_config['idp_sso_service_url'].present?
    end

    def saml_settings
      config = saml_config
      return if config.blank? || config['idp_sso_service_url'].blank?

      {
        idp_sso_service_url: config['idp_sso_service_url'],
        idp_cert: config['idp_cert'],
        idp_cert_fingerprint: config['idp_cert_fingerprint'].presence,
        sp_entity_id: config['sp_entity_id'].presence || "https://#{Docuseal::HOST}/auth/saml/metadata",
        assertion_consumer_service_url: "https://#{Docuseal::HOST}/auth/saml/callback",
        name_identifier_format: 'urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress',
        attribute_statements: {
          email: ['email', 'mail', 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress'],
          first_name: ['first_name', 'given_name', 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname'],
          last_name: ['last_name', 'family_name', 'http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname'],
          role: %w[role]
        }
      }.compact
    end

    def map_role(idp_role)
      idp_role = idp_role.to_s.downcase

      return ROLE_MAP[idp_role] if ROLE_MAP.key?(idp_role)
      return User::CLIENT_ROLE if CLIENT_ROLES.include?(idp_role)

      nil
    end

    # Returns the signed-in user or raises Error with a message safe to show.
    def find_or_create_user(auth)
      info = auth.info || {}
      raw = auth.extra&.raw_info.to_h

      email = info['email'].to_s.downcase.strip
      raise Error, 'Your account has no email address.' if email.blank?

      verified = raw.key?('email_verified') ? ActiveModel::Type::Boolean.new.cast(raw['email_verified']) : true
      raise Error, 'Your email address is not verified.' unless verified

      idp_role = raw['role'] || Array(auth.extra&.response_object&.attributes&.multi(:role)).first
      role = map_role(idp_role)
      raise Error, 'Your account does not have access to this service.' if role.nil?

      account = Account.order(:id).first
      raise Error, 'This service is not set up yet.' unless account

      user = User.find_by(email:)

      if user
        raise Error, 'Your account is not active.' if user.archived_at?

        link = user.user_configs.find_or_initialize_by(key: CONFIG_KEY)
        # A local account signing in by SSO for the first time is linked and keeps its role.
        managed = link.persisted? && link.value.is_a?(Hash) && link.value['managed'] == true
        link.value = { 'provider' => auth.provider, 'sub' => auth.uid, 'managed' => managed }
        user.role = role if managed

        user.first_name = info['first_name'].presence || user.first_name
        user.last_name = info['last_name'].presence || user.last_name
        user.save!
        link.save!
      else
        user = account.users.create!(
          email:,
          first_name: info['first_name'].presence || info['name'].to_s.split.first,
          last_name: info['last_name'].presence || info['name'].to_s.split[1..]&.join(' '),
          role:,
          password: SecureRandom.base58(40)
        )
        user.user_configs.create!(key: CONFIG_KEY,
                                  value: { 'provider' => auth.provider, 'sub' => auth.uid, 'managed' => true })
      end

      user
    end
  end
end
