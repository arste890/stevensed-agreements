# frozen_string_literal: true

module Stevensed
  # StevensED: what a completed envelope can be downloaded as, like DocuSign's download choices.
  #   combined  - the signed documents followed by the audit log, one PDF (the default);
  #   documents - the signed documents only;
  #   audit     - the audit log only.
  # Combined is offered once everyone has signed, except for envelopes with an identity-verification field.
  # The account setting "combine documents and audit log" switched off makes "documents" the default instead.
  module Downloads
    KINDS = %w[combined documents audit].freeze
    FILES_TTL = 5.minutes

    module_function

    def complete?(submission)
      submission.completed_at.present?
    end

    def combined_allowed?(submission)
      complete?(submission) && submission.template_fields.to_a.none? { |f| f['type'] == 'verification' }
    end

    def combined_default?(account_id)
      !AccountConfig.exists?(account_id:, key: AccountConfig::COMBINE_PDF_RESULT_KEY, value: false)
    end

    def kinds(submission)
      [('combined' if combined_allowed?(submission)), 'documents', ('audit' if complete?(submission))].compact
    end

    def default_kind(submission)
      combined_allowed?(submission) && combined_default?(submission.account_id) ? 'combined' : 'documents'
    end

    # The requested kind if available, otherwise the default. Returns nil for an audit log that does not exist yet.
    def resolve(submission, requested)
      requested = requested.to_s
      return requested if kinds(submission).include?(requested)
      return nil if requested == 'audit'

      default_kind(submission)
    end

    def urls(last_submitter, kind)
      case kind
      when 'combined' then [Submitters.build_combined_url(last_submitter)].compact
      when 'audit' then [audit_url(last_submitter)].compact
      else Submitters.build_document_urls(last_submitter, kind: 'documents')
      end
    end

    def audit_url(submitter)
      submission = submitter.submission
      Submissions::EnsureAuditGenerated.call(submission) if submission.audit_trail.blank?
      return if submission.audit_trail.blank?

      filename_format = AccountConfig.find_or_initialize_by(account_id: submitter.account_id,
                                                            key: AccountConfig::DOCUMENT_FILENAME_FORMAT_KEY)&.value

      ActiveStorage::Blob.proxy_path(
        submission.audit_trail.blob, expires_at: FILES_TTL.from_now.to_i,
                                     filename: Submitters.build_document_filename(submitter,
                                                                                  submission.audit_trail.blob,
                                                                                  filename_format)
      )
    end

    def label(kind)
      { 'combined' => 'Combined (documents and audit log)', 'documents' => 'Documents only',
        'audit' => 'Audit log only' }.fetch(kind)
    end
  end
end
