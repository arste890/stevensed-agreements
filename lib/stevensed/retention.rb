# frozen_string_literal: true

module Stevensed
  # StevensED: retention of signed records under the Records Retention Policy (INF-002).
  #
  # FRM-105 (Student Information, Emergency Contact, and Medical Authorization) is kept until the end of the academic
  # year that the form covers plus 3 years (INF-002 §3.3). That period is a minimum; when it ends the record is
  # disposed of under §5, which for an electronic record means deletion from active systems (§2(a), §5(c)).
  # A litigation hold suspends disposal (§2(b), §4).
  #
  # The academic year that a form covers is not a field on FRM-105, so it is taken from the date the form was
  # completed. The form is renewed each academic year (FRM-105 §10). StevensED's academic year runs from the Fall
  # Term to the end of the Summer Term, and its last day is taken as 31 August. A form completed from 1 June
  # onwards may cover the year about to start, so it is treated as covering that later year: disposal may come late,
  # never early.
  #
  # Only a standalone FRM-105 record is disposed of here. A combined envelope (for example First-Time Enrollment)
  # holds FRM-105 pages inside one signed PDF together with forms kept for 7 years (INF-002 §3.1). Removing those
  # pages would break the signed document, so such envelopes are reported for a decision, never changed.
  module Retention
    RULE_FRM105 = 'INF-002 §3.3: FRM-105, end of the academic year it covers plus 3 years'
    FRM105 = 'FRM-105'
    ENVELOPE_FIELD_PREFIX = /\A105\s/
    YEARS_AFTER = 3
    YEAR_END_MONTH = 8
    YEAR_END_DAY = 31
    NEXT_YEAR_FROM_MONTH = 6

    HOLD_KEY = 'stevensed_litigation_hold'

    module_function

    # -- Periods ---------------------------------------------------------------------------------------------------

    def completed_on(submission)
      time = submission.submitters.filter_map(&:completed_at).max

      time&.in_time_zone(submission.account.timezone.presence || 'UTC')&.to_date
    end

    def academic_year_end(date)
      year = date.month >= NEXT_YEAR_FROM_MONTH ? date.year + 1 : date.year

      Date.new(year, YEAR_END_MONTH, YEAR_END_DAY)
    end

    def frm105_period_end(submission)
      date = completed_on(submission)

      return unless date

      academic_year_end(date).advance(years: YEARS_AFTER)
    end

    # -- Which records ---------------------------------------------------------------------------------------------

    def standalone_frm105?(submission)
      key, = Records.form_key_and_version(submission)

      key.to_s.split('-').first(2).join('-') == FRM105
    end

    def envelope_with_frm105?(submission)
      return false if standalone_frm105?(submission)

      submission.template_fields.to_a.any? { |f| f['name'].to_s.match?(ENVELOPE_FIELD_PREFIX) }
    end

    def completed?(submission)
      submission.submitters.any? && submission.submitters.all? { |s| s.completed_at? || s.declined_at? } &&
        submission.submitters.any?(&:completed_at?)
    end

    # -- Litigation holds ------------------------------------------------------------------------------------------

    def hold(submission)
      submission.preferences.to_h[HOLD_KEY].presence
    end

    def held?(submission)
      hold(submission).present?
    end

    def place_hold!(submission, user:, note:)
      note = note.to_s.strip.first(200)
      info = { 'placed_at' => Time.current.iso8601, 'user_id' => user&.id,
               'user_name' => user&.full_name.presence || user&.email, 'note' => note.presence }.compact

      submission.transaction do
        submission.update!(preferences: submission.preferences.to_h.merge(HOLD_KEY => info))
        hold_event!(submission, 'stevensed_hold_placed', info.slice('user_name', 'note'))
      end

      submission
    end

    def release_hold!(submission, user:)
      submission.transaction do
        submission.update!(preferences: submission.preferences.to_h.except(HOLD_KEY))
        hold_event!(submission, 'stevensed_hold_released',
                    'user_name' => user&.full_name.presence || user&.email)
      end

      submission
    end

    def hold_event!(submission, event_type, data)
      signer = submission.submitters.min_by(&:id)

      SubmissionEvent.create!(submitter: signer, event_type:, data: data.compact) if signer
    end

    # -- Sweep -----------------------------------------------------------------------------------------------------

    # Finds FRM-105 records whose period has ended. With apply: true, disposes of each standalone record that is not
    # on hold and returns a summary without personal data: counts, submission IDs, and the envelopes left for a
    # decision. With apply: false (the default) it only reports.
    def sweep(apply: false, today: Time.zone.today)
      result = { 'rule' => RULE_FRM105, 'today' => today.iso8601, 'apply' => apply,
                 'disposed' => [], 'due' => [], 'held' => [], 'envelopes_for_decision' => [], 'errors' => [] }

      candidates.find_each do |submission|
        classify(submission, today, apply, result)
      end

      result.merge('counts' => result.slice('disposed', 'due', 'held', 'envelopes_for_decision', 'errors')
                                     .transform_values(&:size))
    end

    def candidates
      Submission.where.not(template_id: nil).joins(:template)
                .where("templates.external_id ILIKE 'FRM-105%' OR submissions.template_fields::text ~ ?",
                       '"name": ?"105 ')
                .preload(:account, :template, submitters: { documents_attachments: :blob })
    end

    def classify(submission, today, apply, result)
      return unless completed?(submission)

      period_end = frm105_period_end(submission)

      return if period_end.nil? || period_end >= today

      entry = { 'submission_id' => submission.id, 'period_ended_on' => period_end.iso8601 }

      if envelope_with_frm105?(submission)
        result['envelopes_for_decision'] << entry
      elsif !standalone_frm105?(submission)
        nil
      elsif held?(submission)
        result['held'] << entry
      elsif apply
        dispose!(submission, period_end:)
        result['disposed'] << entry
      else
        result['due'] << entry
      end
    rescue StandardError => e
      result['errors'] << { 'submission_id' => submission.id, 'error' => e.class.name }
    end

    # Deletes the record and its files, keeping only the minimal disposal record. Consent records (FRM-102 and
    # others, kept for their own periods) that pointed at this record keep their own data and lose the link.
    def dispose!(submission, period_end:)
      raise ArgumentError, 'record is on a litigation hold' if held?(submission)

      key, version = Records.form_key_and_version(submission)

      submission.transaction do
        StevensedRetentionDisposal.create!(
          account: submission.account, submission_id: submission.id, template_id: submission.template_id,
          document_id: Digest::MD5.hexdigest(submission.slug).upcase, form_key: key, form_version: version&.to_s,
          rule: RULE_FRM105, completed_on: completed_on(submission), period_ended_on: period_end,
          pdf_sha256: IdentityEvents.pdf_hashes(submission), disposed_at: Time.current
        )

        StevensedEsignConsent.where(submission_id: submission.id).update_all(submission_id: nil, submitter_id: nil)

        submission.destroy!
      end
    end
  end
end
