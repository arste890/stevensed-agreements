# frozen_string_literal: true

module Stevensed
  # StevensED: what a completed envelope can be downloaded as:
  #   documents - the completed document;
  #   audit     - the audit log, once everyone has signed;
  #   combined  - the completed document followed by the audit log, one PDF.
  # The main Download button gives signers the completed document (their completion screens and copy link) and gives
  # StevensED staff the combined PDF (submission page, lists), unless the account turns combining off. The menu beside
  # Download offers all three everywhere, with the same labels. Combined is not offered for envelopes with an
  # identity-verification field. Completion emails attach the document and the audit log as separate PDFs.
  module Downloads
    KINDS = %w[documents audit combined].freeze
    FILES_TTL = 5.minutes

    module_function

    def complete?(submission)
      submission.completed_at.present?
    end

    def combined_allowed?(submission)
      complete?(submission) && fields(submission).none? { |f| f['type'] == 'verification' }
    end

    # List queries load submissions without template_fields (select_for_list); read the column on its own then.
    def fields(submission)
      raw =
        if submission.has_attribute?(:template_fields)
          submission.template_fields
        else
          Submission.where(id: submission.id).pick(:template_fields)
        end

      (raw.presence || submission.template&.fields).to_a
    end

    # In menu order: completed document, audit log, combined.
    def kinds(submission)
      ['documents', ('audit' if complete?(submission)), ('combined' if combined_allowed?(submission))].compact
    end

    # The main Download button: the completed document for signers; the combined PDF for staff when available.
    def default_kind(submission, audience: :signer)
      return 'documents' unless audience == :staff

      combined_allowed?(submission) && combined_default?(submission.account_id) ? 'combined' : 'documents'
    end

    def combined_default?(account_id)
      !AccountConfig.exists?(account_id:, key: AccountConfig::COMBINE_PDF_RESULT_KEY, value: false)
    end

    # Pre-generate the combined PDF at completion so the menu choice is quick.
    def pregenerate_combined?(submission)
      combined_allowed?(submission)
    end

    # The requested kind if available, otherwise the default. Returns nil for an audit log that does not exist yet.
    def resolve(submission, requested, audience: :signer)
      requested = requested.to_s
      return requested if kinds(submission).include?(requested)
      return nil if requested == 'audit'

      default_kind(submission, audience:)
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
      { 'documents' => 'Completed document', 'audit' => 'Audit log',
        'combined' => 'Combined (document and audit log)' }.fetch(kind)
    end
  end
end
