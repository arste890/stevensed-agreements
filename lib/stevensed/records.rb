# frozen_string_literal: true

module Stevensed
  # StevensED: lifecycle of signed records. A record stays active even when PolicySync archives its template as a
  # superseded version. It leaves the active list only when (a) the same signer completes a newer version of the same
  # form, which supersedes it automatically, or (b) staff archive it and record a reason. Nothing is deleted; both
  # cases keep the record under Archived and add an event to its event log.
  module Records
    ARCHIVE_KEY = 'stevensed_archive'
    ARCHIVE_REASONS = %w[entered_in_error duplicate withdrawn replaced_by_paper other].freeze

    module_function

    def form_key_and_version(submission)
      match = submission.template&.external_id.to_s.match(PolicySync::FORM_EXTERNAL_ID)

      return unless match

      [match[:key], Gem::Version.new(match[:version])]
    end

    def archive_info(submission)
      submission.preferences.to_h[ARCHIVE_KEY].presence
    end

    # Signer emails that identify the person or family who signed: account users (staff countersigners, shared office
    # mailboxes that belong to users) are left out, so a staff signature never links unrelated families' records.
    def signer_emails(submission)
      staff = submission.account.users.pluck(:email).map(&:downcase)

      submission.submitters.where.not(completed_at: nil).filter_map { |s| s.email&.downcase }.uniq - staff
    end

    # Case (a): called once the newer submission is complete.
    def supersede_earlier!(submission)
      key, version = form_key_and_version(submission)

      return [] unless key && submission.completed_at?

      emails = signer_emails(submission)

      return [] if emails.empty?

      candidates = Submission.where(account_id: submission.account_id, archived_at: nil)
                             .where.not(id: submission.id).where.not(completed_at: nil)
                             .joins(:template).where('templates.external_id LIKE ?', "#{key}\\_v%")
                             .preload(:template, :submitters)

      candidates.filter_map do |earlier|
        earlier_key, earlier_version = form_key_and_version(earlier)

        next unless earlier_key == key && earlier_version < version

        signer = earlier.submitters.find { |s| s.completed_at? && emails.include?(s.email&.downcase) }

        next unless signer

        archive!(earlier, signer:, event_type: 'stevensed_superseded',
                          info: { 'kind' => 'superseded', 'superseded_by_submission_id' => submission.id,
                                  'superseded_by_version' => version.to_s })
      end
    end

    # Case (b): staff archive with a recorded reason.
    def archive_by_staff!(submission, user:, reason:, note: nil)
      reason = ARCHIVE_REASONS.include?(reason.to_s) ? reason.to_s : 'other'

      archive!(submission, signer: submission.submitters.min_by(&:id), event_type: 'stevensed_archived',
                           info: { 'kind' => 'staff', 'reason' => reason, 'note' => note.to_s.strip.presence,
                                   'user_id' => user&.id, 'user_name' => user&.full_name.presence || user&.email })
    end

    def unarchive!(submission, user:)
      signer = submission.submitters.min_by(&:id)

      submission.transaction do
        submission.update!(archived_at: nil, preferences: submission.preferences.to_h.except(ARCHIVE_KEY))

        if signer
          SubmissionEvent.create!(submitter: signer, event_type: 'stevensed_unarchived',
                                  data: { 'user_name' => user&.full_name.presence || user&.email })
        end
      end

      submission
    end

    def archive!(submission, signer:, event_type:, info:)
      info = info.merge('archived_at' => Time.current.iso8601).compact

      submission.transaction do
        submission.update!(archived_at: Time.current,
                           preferences: submission.preferences.to_h.merge(ARCHIVE_KEY => info))

        SubmissionEvent.create!(submitter: signer, event_type:, data: info) if signer
      end

      submission
    end

    # Text for the event log and audit log. Returns nil for other events.
    def event_text(event, submitter_name)
      data = event.data.to_h

      case event.event_type
      when 'stevensed_superseded'
        I18n.t('submission_event_names.stevensed_superseded_by_html',
               envelope: data['superseded_by_submission_id'], version: data['superseded_by_version'], submitter_name:)
      when 'stevensed_archived'
        I18n.t('submission_event_names.stevensed_archived_by_html',
               user: data['user_name'].presence || I18n.t('stevensed.records.staff'),
               reason: [I18n.t("stevensed.records.reasons.#{data['reason']}", default: data['reason'].to_s),
                        data['note']].compact_blank.join(': '))
      when 'stevensed_unarchived'
        I18n.t('submission_event_names.stevensed_unarchived_by_html',
               user: data['user_name'].presence || I18n.t('stevensed.records.staff'))
      end
    end
  end
end
