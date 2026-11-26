# frozen_string_literal: true

module Stevensed
  # StevensED: electronic records and signature consent on file (ESIGN Act, 15 U.S.C. 7001(c)).
  #
  # Before a signer's first document, a consent must be on file for their email address:
  #   - families (parents, guardians, payers, cosigners, adult students): FRM-102-M (student under 18) or FRM-102-A;
  #   - StevensED faculty and staff, or anyone signing in the StevensED role: FRM-505;
  #   - everyone else (job candidates, contractors, vendors): FRM-601.
  # Family envelopes also ask for the student's date of birth on every envelope. The date checks that the envelope is
  # the right version (Minor, Adult, Under 13) and fills the document's own date-of-birth field if it has one; apart
  # from that, only the resulting age band is kept. A mismatch voids
  # the envelope and alerts the Office of Legal Operations so the right envelope can be issued. A minor student
  # signing their own acknowledgment relies on a parent's FRM-102-M on file. Consent is voluntary: a signer may ask for
  # paper instead, which alerts the office. The legal name on the consent becomes the signer's name on later documents.
  module Consents
    CONSENT_FORMS = { 'family_minor' => 'FRM-102-M', 'family_adult' => 'FRM-102-A',
                      'staff' => 'FRM-505', 'general' => 'FRM-601' }.freeze
    FAMILY_KINDS = %w[family_minor family_adult].freeze
    FAMILY_ROLE = /parent|guardian|student|payer|cosigner|family|client/i
    PARENT_ROLE = /parent|guardian/i
    STAFF_ROLE = /\AStevensED\z/i
    LEGAL_NAME_FIELD = /(?:\A|\s)(?:\d+\.\s*)?Full legal name\z/i
    RECORDS_EMAIL_FIELD = /Email address for records and notices\z/i
    NAME_FIELDS = /printed name|full legal name|\Aname\z/i
    # A name field about the student (e.g. "Student name") is the student's name, not the signer's: it is filled with
    # the legal name only when an adult student signs their own Adult document.
    STUDENT_FIELD = /student|child/i
    STUDENT_NAME_FIELD = /\b(?:student|child)(?:'s)?\b.*\bname\b|\bname of (?:the )?(?:student|child)\b/i
    STUDENT_AGE_FIELD = /\b(?:student|child)(?:'s)?\s+age\b|\bage of (?:the )?(?:student|child)\b/i
    DOB_FIELD = /date of birth|birth ?date|\bDOB\b/i
    PACKET_FAMILY = /first-time-enrollment/i
    AGE_BANDS = { 'under_13' => 'under 13', 'under_18' => '13 to 17', 'adult' => '18 or older' }.freeze

    Context = Struct.new(:audience, :variant, :packet, :minor_signer, :contains_consent, keyword_init: true)

    module_function

    # -- Envelope classification ---------------------------------------------------------------------------------

    def context(submitter)
      template = submitter.submission.template
      key = template_key(template)
      label = "#{key} #{template&.name}"
      role = role_name(submitter)
      audience = audience_for(key, role)
      variant = variant_for(label)

      minor_signer = audience == 'family' && role.match?(/\Astudent\z/i) && %w[minor child].include?(variant)

      Context.new(audience:, variant:, packet: key.match?(PACKET_FAMILY), minor_signer:,
                  contains_consent: fields_for(submitter.submission).any? { |f| f['name'].to_s.start_with?('102 ') })
    end

    def template_key(template)
      ext = template&.external_id.to_s

      ext[PolicySync::FORM_EXTERNAL_ID, :key] || template&.preferences.to_h.dig(PolicySync::PREFERENCE_KEY, 'key') ||
        ext.sub(/@\h+\z/, '')
    end

    def audience_for(key, role)
      return 'staff' if role.match?(STAFF_ROLE) || key.match?(/\AFRM-5\d\d/)
      return 'family' if key.match?(/\AFRM-[1-4]\d\d/) || key.match?(PACKET_FAMILY) || role.match?(FAMILY_ROLE)

      'general'
    end

    def variant_for(label)
      case label
      when /U13|Under-13|Under 13|\AFRM-108/i then 'child'
      when /-M(?:\b|_)|Minor/ then 'minor'
      when /-A(?:\b|_)|Adult/ then 'adult'
      end
    end

    def role_name(submitter)
      submitter.submission.template_submitters.to_a.find { |s| s['uuid'] == submitter.uuid }&.dig('name').to_s
    end

    def fields_for(submission)
      submission.template_fields || submission.template&.fields || []
    end

    # -- Age check -----------------------------------------------------------------------------------------------

    def age_in_years(dob, today: Time.current.in_time_zone(PolicySync::TIME_ZONE).to_date)
      today.year - dob.year - (today < dob.next_year(today.year - dob.year) ? 1 : 0)
    end

    def age_band(dob, today: Time.current.in_time_zone(PolicySync::TIME_ZONE).to_date)
      age = age_in_years(dob, today:)

      if age < 13 then 'under_13'
      elsif age < 18 then 'under_18'
      else 'adult'
      end
    end

    # Under 13 envelopes need a child under 13; a Minor packet (without FRM-108) needs 13 to 17; single Minor forms
    # need a student under 18; Adult envelopes need 18 or older. Envelopes that do not say accept any age.
    def band_matches?(ctx, band)
      case ctx.variant
      when 'child' then band == 'under_13'
      when 'minor' then ctx.packet ? band == 'under_18' : band != 'adult'
      when 'adult' then band == 'adult'
      else true
      end
    end

    def expected_label(ctx)
      case ctx.variant
      when 'child' then 'a student under 13'
      when 'minor' then ctx.packet ? 'a student aged 13 to 17' : 'a student under 18'
      when 'adult' then 'a student 18 or older'
      end
    end

    # Keeps the age band (not the date) and fills the signer's own date-of-birth and student age fields, if the
    # document has them. The age is the student's age in years on the day it is entered.
    def store_age!(submitter, dob, band, today: Time.current.in_time_zone(PolicySync::TIME_ZONE).to_date)
      fields = fields_for(submitter.submission).select { |f| f['submitter_uuid'] == submitter.uuid }
      dob_field = fields.find do |f|
        f['type'] == 'date' && f['name'].to_s.match?(DOB_FIELD) &&
          f['name'].to_s.match?(/student|child|\A\d*\.?\s*date of birth/i)
      end
      age_field = fields.find { |f| f['type'].in?(%w[text number]) && f['name'].to_s.match?(STUDENT_AGE_FIELD) }

      values = submitter.values.dup
      values[dob_field['uuid']] = dob.iso8601 if dob_field && values[dob_field['uuid']].blank?
      values[age_field['uuid']] = age_in_years(dob, today:).to_s if age_field && values[age_field['uuid']].blank?

      attrs = { metadata: submitter.metadata.to_h.merge('stevensed_student_age' => band) }
      attrs[:values] = values if values != submitter.values

      submitter.update!(attrs)
    end

    def void!(submitter, ctx, band)
      submission = submitter.submission
      submission.update!(archived_at: Time.current)
      voided = { 'student_age' => band, 'expected' => expected_label(ctx), 'at' => Time.current.iso8601 }
      submitter.update!(metadata: submitter.metadata.to_h.merge('stevensed_voided' => voided))
      Stevensed::ConsentMailer.wrong_version_email(submitter, AGE_BANDS.fetch(band), expected_label(ctx)).deliver_later!
    end

    # -- Consent register ----------------------------------------------------------------------------------------

    def kinds_for(ctx, band = nil)
      case ctx.audience
      when 'family'
        return FAMILY_KINDS unless band

        [band == 'adult' ? 'family_adult' : 'family_minor']
      else [ctx.audience]
      end
    end

    # Family consents count for any family envelope (FRM-102 covers every student the signer later signs for).
    def on_file(account, email, kinds)
      email = email.to_s.strip.downcase
      return if email.blank?

      kinds = FAMILY_KINDS if kinds.intersect?(FAMILY_KINDS)
      StevensedEsignConsent.active.where(account:, email:, kind: kinds).order(signed_at: :desc).first ||
        backfill(account, email, kinds)
    end

    # Records consents signed earlier (a consent form or a packet containing FRM-102) that are not yet registered.
    def backfill(account, email, kinds)
      Submitter.joins(submission: :template).where(account:, email:).where.not(completed_at: nil)
               .order(completed_at: :desc).find_each do |submitter|
        consent = record_from_submitter(submitter)
        return consent if consent && kinds.include?(consent.kind) && consent.withdrawn_at.nil?
      end

      nil
    end

    def consent_form_for(template)
      key = template_key(template)
      kind = CONSENT_FORMS.key(key)
      return [kind, key, template&.external_id.to_s[PolicySync::FORM_EXTERNAL_ID, :version], 'signed'] if kind

      return unless key.match?(PACKET_FAMILY) && template.fields.any? { |f| f['name'].to_s.start_with?('102 ') }

      [key.match?(/-A\z/i) ? 'family_adult' : 'family_minor', key.match?(/-A\z/i) ? 'FRM-102-A' : 'FRM-102-M',
       nil, 'packet']
    end

    def record_from_submitter(submitter)
      return unless submitter.completed_at?

      existing = StevensedEsignConsent.find_by(submitter_id: submitter.id)
      return existing if existing

      kind, form_key, version, source = consent_form_for(submitter.submission.template)
      return unless kind

      fields = fields_for(submitter.submission).select { |f| f['submitter_uuid'] == submitter.uuid }
      legal_name = fields.find { |f| f['name'].to_s.match?(LEGAL_NAME_FIELD) }&.then { |f| submitter.values[f['uuid']] }

      StevensedEsignConsent.create!(account: submitter.account, email: submitter.email, kind:, form_key:,
                                    form_version: version, source:, submission: submitter.submission, submitter:,
                                    legal_name: [legal_name, submitter.name, submitter.email].map { |v| v.to_s.squish }
                                                                                       .find(&:present?),
                                    signed_at: submitter.completed_at)
    end

    def current_template(account, kind, today: Time.current.in_time_zone(PolicySync::TIME_ZONE).to_date)
      key = CONSENT_FORMS.fetch(kind)

      candidates = Template.where(account:, archived_at: nil).where('external_id LIKE ?', "#{key}\\_v%").to_a
      in_effect = candidates.select do |t|
        effective = t.preferences.to_h.dig(PolicySync::PREFERENCE_KEY, 'effective')
        effective.nil? || Date.parse(effective) <= today
      end

      in_effect.max_by { |t| Gem::Version.new(t.external_id[PolicySync::FORM_EXTERNAL_ID, :version]) }
    end

    # Opens (or reuses) a consent envelope for the signer and returns its submitter; it redirects back when signed.
    def start_consent!(submitter, kind, return_url)
      template = current_template(submitter.account, kind)
      return unless template

      open = Submitter.joins(:submission).where(account: submitter.account, email: submitter.email, completed_at: nil,
                                                declined_at: nil, submissions: { template_id: template.id,
                                                                                 archived_at: nil }).last
      if open
        open.update!(preferences: open.preferences.except('send_email').merge('completed_redirect_url' => return_url))
        return open
      end

      author = template.author || submitter.account.users.where(role: User::ADMIN_ROLE).order(:id).first
      submission = Submissions.create_from_emails(template:, user: author, emails: [submitter.email],
                                                  source: 'invite', mark_as_sent: true).first
      consent_submitter = submission.submitters.first
      email_field = template.fields.find { |f| f['name'].to_s.match?(RECORDS_EMAIL_FIELD) }

      # Emails stay on (no 'send_email' => false), so the signer gets a copy of the signed consent like any other
      # document, and a parent asked to sign one (parent_consent) gets the request.
      preferences = consent_submitter.preferences.except('send_email').merge('completed_redirect_url' => return_url)
      consent_submitter.update!(name: submitter.name,
                                values: email_field ? { email_field['uuid'] => submitter.email } : {}, preferences:,
                                metadata: { 'stevensed_consent_for' => submitter.id })
      consent_submitter
    end

    # A minor student relies on a parent's family consent; when none is on file, the parent is asked to sign one.
    def parent_consent(submitter)
      parents = submitter.submission.submitters.select { |s| role_name(s).match?(PARENT_ROLE) && s.email.present? }
      found = parents.lazy.filter_map { |p| on_file(submitter.account, p.email, FAMILY_KINDS) }.first
      return found if found || submitter.metadata.to_h['stevensed_parent_consent_requested']

      parent = parents.first
      if parent && (consent_submitter = start_consent!(parent, 'family_minor', nil))
        Submissions.send_signature_requests([consent_submitter.submission])
      else
        Stevensed::ConsentMailer.parent_consent_missing_email(submitter).deliver_later!
      end
      requested = { 'stevensed_parent_consent_requested' => Time.current.iso8601 }
      submitter.update!(metadata: submitter.metadata.to_h.merge(requested))
      nil
    end

    # -- Gate ----------------------------------------------------------------------------------------------------

    def accepted?(submitter)
      submitter.submission_events.exists?(event_type: :accept_esign_consent)
    end

    # Returns the gate state for the signing page, recording the acceptance when a consent is already on file:
    # :none, :dob, :sign_consent, :parent_required or :checkbox.
    def prepare(submitter, request)
      return :none if submitter.viewer? || submitter.completed_at? || submitter.declined_at? || accepted?(submitter)

      # The consent form itself is the consent: no gate on it.
      if consent_form_for(submitter.submission.template)&.last == 'signed'
        accept!(submitter, request, source: 'in_envelope')
        return :none
      end

      ctx = context(submitter)
      band = submitter.metadata.to_h['stevensed_student_age']
      return :dob if ctx.audience == 'family' && !ctx.minor_signer && band.blank?

      consent =
        if ctx.minor_signer then parent_consent(submitter)
        else on_file(submitter.account, submitter.email, kinds_for(ctx, band))
        end
      return :parent_required if ctx.minor_signer && consent.nil?

      if consent || (ctx.audience == 'family' && ctx.contains_consent)
        accept!(submitter, request, consent:, band:, via_parent: ctx.minor_signer)
        return :none
      end

      current_template(submitter.account, kinds_for(ctx, band).first) ? :sign_consent : :checkbox
    end

    def accept!(submitter, request, consent: nil, band: nil, via_parent: false, source: nil)
      data = { 'student_age' => band, 'source' => source || (consent ? 'on_file' : 'in_envelope'),
               'via_parent' => via_parent || nil }
      if consent
        data.merge!('consent_form' => consent.label, 'consent_signed_at' => consent.signed_at.utc.iso8601,
                    'consent_envelope' => consent.submission_id, 'consent_id' => consent.id)
        apply_name!(submitter, consent) unless via_parent
      end

      SubmissionEvents.create_with_tracking_data(submitter, 'accept_esign_consent', request, data.compact)
    end

    # The legal name on the consent becomes the signer's name: printed-name fields are filled and locked, and the
    # typed signature defaults to it.
    def apply_name!(submitter, consent)
      name = consent.legal_name
      submission = submitter.submission
      # Copy fields, schema, variables and submitters from the template together, as upstream does, so that
      # completion (which reads template_schema) works once template_fields is set on the submission.
      Submissions.update_template_fields!(submission) if submission.template_fields.blank?
      fields = fields_for(submission).deep_dup
      values = submitter.values.dup
      own_student_form = adult_student_signer?(submitter)

      fields.each do |f|
        next unless f['submitter_uuid'] == submitter.uuid && f['type'] == 'text' &&
                    legal_name_field?(f['name'], own_student_form)

        values[f['uuid']] = name
        f['readonly'] = true
        f['default_value'] = name
      end

      submission.update!(template_fields: fields) if fields != fields_for(submission)
      submitter.update!(name:, values:, metadata: submitter.metadata.to_h.merge('stevensed_legal_name' => name))
    end

    # Printed-name fields take the signer's legal name. Fields about the student take it only when the student signs
    # their own Adult document; a parent signing for a minor never has the student's name filled with their own.
    def legal_name_field?(name, own_student_form)
      name = name.to_s
      return own_student_form && name.match?(STUDENT_NAME_FIELD) if name.match?(STUDENT_FIELD)

      name.match?(NAME_FIELDS)
    end

    # An Adult document, or one without a version whose student was confirmed to be 18 or older at the gate.
    def adult_student_signer?(submitter)
      return false unless role_name(submitter).match?(/\Astudent\z/i)

      variant = context(submitter).variant
      variant == 'adult' || (variant.nil? && submitter.metadata.to_h['stevensed_student_age'] == 'adult')
    end

    # One or two lines for the signer's block in the audit log.
    # With a time zone, times are written in the StevensED date style (Stevensed.format_datetime); otherwise
    # as UTC ISO 8601.
    def audit_line(event, timezone: nil)
      data = event.data.to_h
      stamp = ->(time) { timezone ? Stevensed.format_datetime(time, timezone) : time.utc.iso8601 }
      at = stamp.call(event.event_timestamp)
      line =
        if data['consent_form']
          "Electronic records consent on file#{' (parent or guardian)' if data['via_parent']}: " \
            "#{data['consent_form']} signed #{signed_at(data['consent_signed_at'], stamp, timezone)}" \
            "#{" (envelope #{data['consent_envelope']})" if data['consent_envelope']}, confirmed #{at}"
        elsif data['source'] == 'in_envelope'
          "Electronic records consent: given in this envelope, #{at}"
        else
          "Electronic records consent: accepted #{at}"
        end
      line += "\nStudent age confirmed: #{AGE_BANDS.fetch(data['student_age'], data['student_age'])}" if
        data['student_age']

      "#{line}\n"
    end

    def signed_at(value, stamp, timezone)
      timezone && value.present? ? stamp.call(Time.zone.parse(value)) : value
    end

    def request_paper!(submitter)
      submitter.update!(metadata: submitter.metadata.to_h.merge('stevensed_paper_requested' => Time.current.iso8601))
      Stevensed::ConsentMailer.paper_request_email(submitter).deliver_later!
    end
  end
end
