# frozen_string_literal: true

# StevensED: single sign-on. OpenID Connect is configured by environment (OIDC_*); SAML by
# Settings > SSO (EncryptedConfig 'saml_configs'), read on each request in the setup phase.
OmniAuth.config.logger = Rails.logger
OmniAuth.config.allowed_request_methods = %i[post]
OmniAuth.config.path_prefix = '/auth'
OmniAuth.config.on_failure = proc { |env| OmniauthCallbacksController.action(:failure).call(env) }

STEVENSED_OIDC_OPTIONS = {
  name: :stevensed,
  issuer: ENV.fetch('OIDC_ISSUER', 'https://auth.stevensed.org'),
  discovery: true,
  scope: %i[openid email profile],
  response_type: :code,
  pkce: true,
  client_auth_method: :basic,
  client_options: {
    identifier: ENV.fetch('OIDC_CLIENT_ID', nil),
    secret: ENV.fetch('OIDC_CLIENT_SECRET', nil),
    redirect_uri: "https://#{ENV.fetch('HOST', 'localhost')}/auth/stevensed/callback"
  }
}.freeze

STEVENSED_SAML_SETUP = lambda do |env|
  config = Stevensed::Sso.saml_settings
  strategy = env['omniauth.strategy']

  config ? strategy.options.merge!(config) : strategy.options[:idp_sso_service_url] = nil
end

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :openid_connect, STEVENSED_OIDC_OPTIONS if ENV['OIDC_CLIENT_ID'].present?
  provider :saml, setup: STEVENSED_SAML_SETUP
end
