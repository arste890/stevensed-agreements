# frozen_string_literal: true

module Stevensed
  # StevensED: events for auth.stevensed.org (the StevensED identity provider).
  #
  # When an envelope is completed, declined, or archived by staff with a reason, Agreements sends a signed event to
  # POST /api/v1/agreements/events on auth.stevensed.org. The event carries references only (envelope number, form key
  # and version, Document ID, the signed PDFs' SHA-256, times), the student and household IDs that identity attached
  # when it sent the envelope, and the facts agreed for that form (FRM-108 section 11 and the parent's choice; the
  # student's date of birth, owner, 27 November 2026). No PDF, signature image or other form contents leave Agreements.
  #
  # Signing: HMAC-SHA256 over "<timestamp>.<body>" with the shared secret STEVENSED_IDENTITY_EVENTS_SECRET, sent as
  # X-StevensED-Signature: v1=<hex>, with X-StevensED-Timestamp and X-StevensED-Event-Id. Identity rejects a timestamp
  # more than five minutes away and ignores an event ID it has already applied. Delivery is retried with back-off by
  # Sidekiq (StevensedIdentityEventJob); identity's daily reconcile reads GET /stevensed/identity/events for any
  # completion it has not seen.
  #
  # Requests from identity to Agreements (the reconcile and "Send for signature") are signed the same way over
  # "<timestamp>.<METHOD>.<path and query>.<body>" and verified by .verify_request.
  module IdentityEvents
    URL_ENV = 'STEVENSED_IDENTITY_EVENTS_URL'
    SECRET_ENV = 'STEVENSED_IDENTITY_EVENTS_SECRET'
    SIGNATURE_HEADER = 'X-StevensED-Signature'
    TIMESTAMP_HEADER = 'X-StevensED-Timestamp'
    EVENT_ID_HEADER = 'X-StevensED-Event-Id'
    TOLERANCE = 300
    SCHEMA_VERSION = 1

    # Submitter metadata keys set when identity sends an envelope (StevensedIdentityController#create_envelope).
    STUDENT_ID_KEY = 'stevensed_student_id'
    HOUSEHOLD_ID_KEY = 'stevensed_household_id'
    REQUEST_ID_KEY = 'stevensed_request_id'
    SENT_BY_KEY = 'stevensed_sent_by'

    # Forms whose events identity acts on in phase 1. Other managed forms are not sent.
    CONSENT_FORM = 'FRM-108'
    BIRTH_YEAR_FORMS = %w[FRM-101 FRM-103 FRM-105].freeze
    MEDIA_FORM = 'FRM-301'
    # Family forms (FRM-101 to FRM-499): identity keeps a reference to each for "Forms on file" in the StevensED app.
    # Faculty and staff forms (FRM-5xx) and general forms (FRM-6xx) stay in Agreements only.
    FAMILY_FORM = /\AFRM-[1-4]\d{2}\z/
    FAMILY_EXTERNAL_IDS = '^FRM-[1-4][0-9]{2}(-[A-Z0-9]+)?_v'

    # FRM-301 media choices (sections 1 and 2; 3.2 and later). The under-13 version adds section 8, completed by
    # StevensED after verifying the parent, like FRM-108 section 11.
    FRM301_CHOICES = {
      'a' => /\A2\.\s*\(a\)/, 'b' => /\A2\.\s*\(b\)/, 'c' => /\A2\.\s*\(c\)/, 'd' => /\A2\.\s*\(d\)/,
      'e' => /\A2\.\s*\(e\)/, 'f' => /\A2\.\s*\(f\)/, 'g' => /\A2\.\s*\(g\)/
    }.freeze
    FRM301_NAMES = { 'none' => /\A2\.\s*No name\z/i, 'first' => /\A2\.\s*First name only\z/i,
                     'full' => /\A2\.\s*Full name\z/i }.freeze
    FRM301_FIELDS = {
      student_name: /\A1\.\s*Student name\z/i, academic_year: /\A1\.\s*Academic year\z/i,
      student_dob: /\A1\.\s*Student date of birth\z/i,
      verified_on: /\A8\.\s*Parent consent verified by StevensED staff on/i, staff: /\A8\.\s*StevensED staff member\z/i,
      form_version: /\A8\.\s*Form version\z/i, method: /\A8\.\s*StevensED use only\z/i
    }.freeze

    # FRM-108 field names (v4.6 and later).
    FRM108_FIELDS = {
      student_name: /\A1\.\s*Student legal name\z/i,
      student_dob: /\A1\.\s*Student date of birth\z/i,
      parent_name: %r{\A1\.\s*Parent/guardian full name\z}i,
      parent_email: %r{\A1\.\s*Parent/guardian email on file\z}i,
      choice: /\A9\.\s*Your choice\z/i,
      verified_on: /\A11\.\s*Parent consent verified by StevensED staff on/i,
      staff: /\A11\.\s*StevensED staff member\z/i,
      form_version: /\A11\.\s*Form version\z/i,
      method: /\A11\.\s*StevensED use only\z/i
    }.freeze

    # FRM-108 section 11 methods, as printed on the form, to identity's consent method codes (lib/children.js
    # CONSENT_METHODS). FRM-108 4.x has one box for "Video call or in person"; StevensED used it only for meetings in
    # person (owner, 27 November 2026), so it is recorded as in_person. FRM-108 5.0 and later have separate boxes.
    METHODS = {
      'identity check' => 'photo_id_match',
      'payment' => 'payment',
      'video call or in person' => 'in_person',
      'video call' => 'video',
      'in person' => 'in_person',
      'signed form returned' => 'signed_return',
      'government id check' => 'government_id'
    }.freeze

    DOB_FIELD = /\A1\.\s*(?:(?:Applicant|Student)\s+)?date of birth\z/i
    STUDENT_NAME_FIELD = /\A1\.\s*(?:Student|Applicant)(?:'s)?\s+(?:legal\s+|full\s+)?name\z/i

    module_function

    def url
      ENV.fetch(URL_ENV, '').presence
    end

    def secret
      ENV.fetch(SECRET_ENV, '').presence
    end

    def configured?
      url.present? && secret.present?
    end

    def form_base(key)
      key.to_s[/\AFRM-\d{3}/]
    end

    def relevant?(submission)
      key, = Records.form_key_and_version(submission)

      form_base(key).to_s.match?(FAMILY_FORM)
    end

    # -- Enqueueing ------------------------------------------------------------------------------------------------

    def enqueue_completed(submission)
      enqueue('envelope.completed', submission, event_id: "agr_#{submission.id}_completed")
    end

    def enqueue_declined(submitter)
      submission = submitter.submission

      enqueue('envelope.declined', submission, event_id: "agr_#{submission.id}_declined_#{submitter.id}",
                                               submitter_id: submitter.id)
    end

    def enqueue_archived(submission)
      info = Records.archive_info(submission) || {}

      return unless info['kind'] == 'staff'

      at = Time.zone.parse(info['archived_at'].to_s) || submission.archived_at || Time.current

      enqueue('envelope.archived', submission, event_id: "agr_#{submission.id}_archived_#{at.to_i}")
    end

    def enqueue(type, submission, event_id:, submitter_id: nil)
      return unless configured? && relevant?(submission)

      StevensedIdentityEventJob.perform_async('type' => type, 'submission_id' => submission.id,
                                              'submitter_id' => submitter_id, 'event_id' => event_id)
    rescue StandardError => e
      # Never stop the signing flow over the event channel; the daily reconcile catches completions.
      Rails.logger.error("StevensED identity event not queued: #{e.class}")
    end

    # -- The event -------------------------------------------------------------------------------------------------

    def build(type, submission, event_id:, submitter: nil, at: Time.current)
      key, version = Records.form_key_and_version(submission)
      base = form_base(key)

      {
        'schema' => SCHEMA_VERSION,
        'id' => event_id,
        'type' => type,
        'created_at' => at.utc.iso8601,
        'envelope' => envelope(submission, key, version),
        'links' => links(submission),
        'signers' => signers(submission),
        'facts' => type == 'envelope.completed' ? facts(base, submission) : {},
        'declined' => (decline_details(submitter) if type == 'envelope.declined'),
        'archived' => (archive_details(submission) if type == 'envelope.archived')
      }.compact
    end

    def envelope(submission, key, version)
      {
        'id' => submission.id,
        'form_key' => key,
        'form' => form_base(key),
        'form_version' => version&.to_s,
        'title' => submission.template&.name.to_s.sub(/\s*\(from [^)]*\)\z/, '').presence,
        'template_id' => submission.template_id,
        'document_id' => Digest::MD5.hexdigest(submission.slug).upcase,
        'pdf_sha256' => pdf_hashes(submission),
        'created_at' => submission.created_at&.utc&.iso8601,
        'completed_at' => submission.completed_at&.utc&.iso8601,
        'archived_at' => submission.archived_at&.utc&.iso8601,
        'superseded_by' => Records.archive_info(submission)&.dig('superseded_by_submission_id')
      }.compact
    end

    # The signed documents' hashes (computed by Agreements when it generated them), never the documents.
    def pdf_hashes(submission)
      last = submission.submitters.select(&:completed_at?).max_by(&:completed_at)

      return [] unless last

      last.documents.filter_map { |a| a.metadata.to_h['sha256'].presence }
    end

    def links(submission)
      meta = submission.submitters.map { |s| s.metadata.to_h }

      {
        'student_id' => meta.filter_map { |m| m[STUDENT_ID_KEY].presence }.first,
        'household_id' => meta.filter_map { |m| m[HOUSEHOLD_ID_KEY].presence }.first,
        'sent_by' => meta.filter_map { |m| m[SENT_BY_KEY].presence }.first
      }.compact
    end

    def signers(submission)
      roles = submission.template_submitters.to_a.index_by { |s| s['uuid'] }

      submission.submitters.sort_by(&:id).map do |s|
        {
          'role' => roles.dig(s.uuid, 'name'),
          'email' => s.email&.downcase,
          'staff' => submission.account.users.exists?(email: s.email.to_s.downcase),
          'completed_at' => s.completed_at&.utc&.iso8601,
          'declined_at' => s.declined_at&.utc&.iso8601
        }.compact
      end
    end

    def decline_details(submitter)
      return {} unless submitter

      event = submitter.submission_events.where(event_type: 'decline_form').order(:id).last

      { 'role' => submitter.submission.template_submitters.to_a.find { |s| s['uuid'] == submitter.uuid }&.dig('name'),
        'at' => submitter.declined_at&.utc&.iso8601,
        'reason' => event&.data.to_h['reason'].to_s.strip.presence&.first(500) }.compact
    end

    def archive_details(submission)
      info = Records.archive_info(submission) || {}

      { 'reason' => info['reason'], 'note' => info['note'].to_s.first(500).presence, 'by' => info['user_name'],
        'at' => info['archived_at'] }.compact
    end

    # -- Facts by form ---------------------------------------------------------------------------------------------

    def facts(base, submission)
      case base
      when CONSENT_FORM then frm108_facts(submission)
      when *BIRTH_YEAR_FORMS then birth_year_facts(submission)
      when MEDIA_FORM then frm301_facts(submission)
      else {}
      end
    end

    def frm108_facts(submission)
      v = FRM108_FIELDS.transform_values { |re| value_for(submission, re) }
      method_label = v[:method].to_s.strip
      section11 = {
        'verified_on' => date_only(v[:verified_on]),
        'staff' => v[:staff].to_s.squish.presence,
        'form_version' => v[:form_version].to_s.strip.presence,
        'method_label' => method_label.presence,
        'method' => METHODS[method_label.downcase]
      }

      {
        'student_name' => v[:student_name].to_s.squish.presence,
        'student_birth_date' => birth_date(v[:student_dob]),
        'student_birth_year' => year_only(v[:student_dob]),
        'parent_name' => v[:parent_name].to_s.squish.presence,
        'parent_email' => v[:parent_email].to_s.strip.downcase.presence,
        'choice' => choice(v[:choice]),
        'section_11' => section11.compact,
        'section_11_complete' => section11.values_at('verified_on', 'staff', 'form_version', 'method').all?(&:present?)
      }.compact
    end

    def birth_year_facts(submission)
      dob = value_for(submission, DOB_FIELD)

      { 'student_name' => value_for(submission, STUDENT_NAME_FIELD).to_s.squish.presence,
        'birth_date' => birth_date(dob), 'birth_year' => year_only(dob) }.compact
    end

    def frm301_facts(submission)
      v = FRM301_FIELDS.transform_values { |re| value_for(submission, re) }
      under13 = fields(submission).any? { |f| f['name'].to_s.match?(FRM301_FIELDS[:verified_on]) }
      choices = FRM301_CHOICES.transform_values { |re| checked?(value_for(submission, re)) }
      name = FRM301_NAMES.find { |_, re| checked?(value_for(submission, re)) }&.first
      facts = { 'student_name' => v[:student_name].to_s.squish.presence,
                'academic_year' => v[:academic_year].to_s.squish.presence,
                'choices' => choices, 'name_display' => name, 'under_13' => under13 }

      return facts.compact unless under13

      label = v[:method].to_s.strip
      section8 = { 'verified_on' => date_only(v[:verified_on]), 'staff' => v[:staff].to_s.squish.presence,
                   'form_version' => v[:form_version].to_s.strip.presence, 'method_label' => label.presence,
                   'method' => METHODS[label.downcase] }

      facts.merge('student_birth_date' => birth_date(v[:student_dob]), 'section_8' => section8.compact,
                  'section_8_complete' => section8.values_at('verified_on', 'staff', 'form_version', 'method')
                                                  .all?(&:present?)).compact
    end

    def checked?(value)
      value == true || value.to_s.strip.downcase.in?(%w[true 1 yes on checked])
    end

    def choice(value)
      case value.to_s.strip.downcase
      when 'i consent' then 'consent'
      when 'i do not consent' then 'no_consent'
      end
    end

    def date_only(value)
      value.to_s[/\A\d{4}-\d{2}-\d{2}/]
    end

    def birth_date(value)
      date_only(value) if year_only(value)
    end

    def year_only(value)
      year = value.to_s[/\A(\d{4})-\d{2}-\d{2}/, 1]&.to_i

      year if year && year >= 1900 && year <= Time.current.year
    end

    def fields(submission)
      submission.template_fields.presence || submission.template&.fields || []
    end

    def value_for(submission, name_regexp)
      field = fields(submission).find { |f| f['name'].to_s.strip.match?(name_regexp) }

      return unless field

      submitter = submission.submitters.find { |s| s.uuid == field['submitter_uuid'] }

      submitter&.values.to_h[field['uuid']]
    end

    # -- Signing ---------------------------------------------------------------------------------------------------

    def signature(timestamp, body, key: secret)
      "v1=#{OpenSSL::HMAC.hexdigest('SHA256', key.to_s, "#{timestamp}.#{body}")}"
    end

    def headers_for(body, event_id: nil, now: Time.current)
      ts = now.to_i.to_s

      { 'Content-Type' => 'application/json', TIMESTAMP_HEADER => ts, SIGNATURE_HEADER => signature(ts, body),
        EVENT_ID_HEADER => event_id, 'User-Agent' => 'StevensED Agreements' }.compact
    end

    # A request from identity: "<timestamp>.<METHOD>.<path and query>.<body>".
    def verify_request(request, now: Time.current)
      return false unless configured?

      ts = request.headers[TIMESTAMP_HEADER].to_s
      given = request.headers[SIGNATURE_HEADER].to_s

      return false unless ts.match?(/\A\d{9,11}\z/) && (now.to_i - ts.to_i).abs <= TOLERANCE

      body = request.raw_post.to_s
      expected = signature(ts, "#{request.request_method}.#{request.fullpath}.#{body}")

      ActiveSupport::SecurityUtils.secure_compare(expected, given)
    end
  end
end
