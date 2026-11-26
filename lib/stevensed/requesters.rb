# frozen_string_literal: true

module Stevensed
  # StevensED: "Send as" for signature requests. A requester is a hash with an optional 'name' (the sender's
  # full name) and an optional 'office' (from the admin-managed office list). It is chosen in the send dialog,
  # stored in submission.preferences['requester'], and used for "Requested by" and the From display name.
  module Requesters
    OFFICES_KEY = 'stevensed_offices'
    DEFAULT_OFFICES = ['StevensED Administration', 'Office of Legal Operations & Institutional Compliance'].freeze
    MAX_OFFICE_LENGTH = 120
    SEPARATOR = '|'

    module_function

    def offices(account)
      list = AccountConfig.find_by(account:, key: OFFICES_KEY)&.value

      list.is_a?(Array) && list.any? ? list : DEFAULT_OFFICES
    end

    def normalize_offices(text)
      text.to_s.split(/\r?\n/).map { |e| e.squish.first(MAX_OFFICE_LENGTH) }.compact_blank.uniq
    end

    def profile_office(user)
      return if user.blank?

      office = user.user_configs.find_by(key: UserConfig::OFFICE_KEY)&.value.presence

      office if office && offices(user.account).include?(office)
    end

    # Options for the send dialog: [label, value] pairs, grouped as { group_label => options }.
    def options(user)
      list = offices(user.account)
      name = user.full_name.presence || user.email

      with_name = [[label('name' => name), encode(:name, nil)]]
      with_name += list.map { |o| [label('name' => name, 'office' => o), encode(:name, o)] }

      {
        I18n.t('stevensed.send_as_with_name') => with_name,
        I18n.t('stevensed.send_as_office_only') => list.map { |o| [o, encode(:office, o)] }
      }
    end

    def default_value(user)
      encode(:name, profile_office(user))
    end

    def encode(kind, office)
      [kind, office].join(SEPARATOR)
    end

    # Builds a requester from a send dialog value; offices outside the admin list are rejected.
    def build(user, value)
      return if value.blank?

      kind, office = value.to_s.split(SEPARATOR, 2)
      office = office.presence

      return if office && offices(user.account).exclude?(office)
      return if kind == 'office' && office.blank?
      return unless kind.in?(%w[name office])

      { 'name' => (user.full_name.presence || user.email if kind == 'name'), 'office' => office }.compact
    end

    def for_submission(submission)
      requester = submission&.preferences&.dig('requester')

      return requester if requester.is_a?(Hash) && requester.values.any?(&:present?)

      user = submission&.created_by_user

      { 'name' => user&.full_name.presence, 'office' => profile_office(user) }.compact
    end

    # "Alec Stevens, Office of the Bursar", "Office of the Bursar" or "Alec Stevens, StevensED".
    def label(requester)
      name = requester['name'].presence
      office = requester['office'].presence

      return [name, office || Stevensed::ORGANIZATION].join(', ') if name

      office || Stevensed::ORGANIZATION
    end

    # Signer-facing eyebrow on the consent step: "From Office of the Bursar", or "From StevensED" without an office.
    def from_label(requester)
      "From #{requester.to_h['office'].presence || Stevensed::ORGANIZATION}"
    end

    # From display name: an office on its own is followed by the organization unless it already names it.
    def from_name(requester)
      return label(requester) if requester['name'].present?

      office = requester['office'].presence || Stevensed::ORGANIZATION

      office.include?(Stevensed::ORGANIZATION) ? office : "#{office}, #{Stevensed::ORGANIZATION}"
    end

    def from_address(requester)
      address = Mail::Address.new(Stevensed::CONTACT_EMAIL)
      address.display_name = from_name(requester)
      address.format
    end
  end
end
