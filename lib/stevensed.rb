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
  LEGAL_ENTITY = 'StevensED LLC'
  PKI_URL = ENV.fetch('STEVENSED_PKI_URL', 'https://pki.stevensed.org/')
  SOURCE_URL = ENV.fetch('SOURCE_URL', 'https://github.com/arste890/stevensed-agreements')
  UPSTREAM_URL = 'https://github.com/docusealco/docuseal'
  LOGO_PATH = '/stevensed/logo-lockup.svg'
  EMAIL_LOGO_PATH = '/stevensed/logo-email.png'
  SHOW_UPSTREAM_LINKS = false
  SIGN_REASON = "Signed with #{PRODUCT_NAME}".freeze

  module_function

  # StevensED date style: 26 November 2026, and 26 November 2026, 12:12 PM MST with the time.
  DATE_FORMAT = '%-d %B %Y'
  DATETIME_FORMAT = '%-d %B %Y, %-I:%M %p'
  DATETIME_SECONDS_FORMAT = '%-d %B %Y, %-I:%M:%S %p'

  def format_date(date)
    I18n.l(date.to_date, format: DATE_FORMAT)
  end

  def format_datetime(time, timezone, seconds: false)
    time = time.in_time_zone(timezone)

    "#{I18n.l(time, format: seconds ? DATETIME_SECONDS_FORMAT : DATETIME_FORMAT)} " \
      "#{TimeUtils.timezone_abbr(timezone, time)}"
  end

  # Letter for accounts in a US time zone, A4 otherwise. Used for the audit log and for HTML-built forms.
  def page_size(account)
    abbr = TimeUtils.timezone_abbr(account&.timezone, Time.current.beginning_of_year)

    abbr.in?(TimeUtils::US_TIMEZONES) ? :Letter : :A4
  end

  def logo_url(account = nil)
    if account.respond_to?(:logo) && account.logo.attached?
      "/account_logo/#{account.uuid}?v=#{account.logo.blob.checksum.to_s.first(8).tr('+/=', '-_.')}"
    else
      LOGO_PATH
    end
  end
end
