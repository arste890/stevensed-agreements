# frozen_string_literal: true

# StevensED: single sign-on. OpenID Connect is configured by environment (OIDC_*); SAML by
# Settings > SSO (EncryptedConfig 'saml_configs'), read on each request in the setup phase.
OmniAuth.config.logger = Rails.logger
OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.path_prefix = '/auth'
OmniAuth.config.on_failure = proc { |env| OmniauthCallbacksController.action(:failure).call(env) }

Rails.application.config.middleware.use OmniAuth::Builder do
  if ENV['OIDC_CLIENT_ID'].present?
    issuer = ENV.fetch('OIDC_ISSUER', 'https://auth.stevensed.org')

    provider :openid_connect,
             name: :stevensed,
             issuer:,
             discovery: true,
             scope: %i[openid email profile],
             response_type: :code,
             pkce: true,
             client_auth_method: :basic,
             client_options: {
               identifier: ENV.fetch('OIDC_CLIENT_ID'),
               secret: ENV.fetch('OIDC_CLIENT_SECRET', nil),
               redirect_uri: "https://#{ENV.fetch('HOST', 'localhost')}/auth/stevensed/callback"
             }
  end

  provider :saml,
           setup: lambda { |env|
             config = Stevensed::Sso.saml_settings
             strategy = env['omniauth.strategy']

             if config
               strategy.options.merge!(config)
             else
               strategy.options[:idp_sso_service_url] = nil
             end
           }
end
