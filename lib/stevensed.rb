# frozen_string_literal: true

# StevensED fork settings. Upstream: DocuSeal (https://github.com/docusealco/docuseal), AGPLv3 with
# Section 7(b) additional terms. The original DocuSeal attribution is retained on the Legal notices page.
module Stevensed
  PRODUCT_NAME = ENV.fetch('PRODUCT_NAME', 'StevensED Agreements')
  ORGANIZATION = 'StevensED'
  OFFICE = ENV.fetch('STEVENSED_OFFICE', 'Office of Legal Operations and Institutional Compliance')
  WEBSITE_URL = 'https://stevensed.org'
  PRIVACY_URL = 'https://stevensed.org/privacy'
  TERMS_URL = 'https://stevensed.org/terms'
  CONTACT_EMAIL = ENV.fetch('STEVENSED_CONTACT_EMAIL', 'legal@stevensed.org')
  SOURCE_URL = ENV.fetch('SOURCE_URL', 'https://github.com/arste890/stevensed-agreements')
  UPSTREAM_URL = 'https://github.com/docusealco/docuseal'
  LOGO_PATH = '/stevensed/logo-color.png'
  EMAIL_LOGO_PATH = '/stevensed/logo-email.png'
  SHOW_UPSTREAM_LINKS = false
  SIGN_REASON = "Signed with #{PRODUCT_NAME}".freeze

  module_function

  def logo_url(account = nil)
    if account.respond_to?(:logo) && account.logo.attached?
      "/account_logo/#{account.uuid}?v=#{account.logo.blob.checksum.to_s.first(8).tr('+/=', '-_.')}"
    else
      LOGO_PATH
    end
  end
end
