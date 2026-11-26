# frozen_string_literal: true

# == Schema Information
#
# Table name: account_configs
#
#  id         :bigint           not null, primary key
#  key        :string           not null
#  value      :text             not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :bigint           not null
#
# Indexes
#
#  index_account_configs_on_account_id          (account_id)
#  index_account_configs_on_account_id_and_key  (account_id,key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class AccountConfig < ApplicationRecord
  SUBMITTER_INVITATION_EMAIL_KEY = 'submitter_invitation_email'
  SUBMITTER_VIEW_INVITATION_EMAIL_KEY = 'submitter_view_invitation_email'
  SUBMITTER_INVITATION_REMINDER_EMAIL_KEY = 'submitter_invitation_reminder_email'
  SUBMITTER_COMPLETED_EMAIL_KEY = 'submitter_completed_email'
  SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY = 'submitter_documents_copy_email'
  BCC_EMAILS = 'bcc_emails'
  FORCE_MFA = 'force_mfa'
  ALLOW_TYPED_SIGNATURE = 'allow_typed_signature'
  ALLOW_TO_RESUBMIT = 'allow_to_resubmit'
  ALLOW_TO_DECLINE_KEY = 'allow_to_decline'
  ALLOW_TO_DELEGATE_KEY = 'allow_to_delegate'
  ALLOW_TO_PARTIAL_DOWNLOAD_KEY = 'allow_to_partial_download'
  SUBMITTER_REMINDERS = 'submitter_reminders'
  ENFORCE_SIGNING_ORDER_KEY = 'enforce_signing_order'
  FORM_COMPLETED_BUTTON_KEY = 'form_completed_button'
  FORM_COMPLETED_MESSAGE_KEY = 'form_completed_message'
  FORM_WITH_CONFETTI_KEY = 'form_with_confetti'
  FORM_PREFILL_SIGNATURE_KEY = 'form_prefill_signature'
  ESIGNING_PREFERENCE_KEY = 'esigning_preference'
  DOWNLOAD_LINKS_AUTH_KEY = 'download_links_auth'
  DOWNLOAD_LINKS_EXPIRE_KEY = 'download_links_expire'
  FORCE_SSO_AUTH_KEY = 'force_sso_auth'
  FLATTEN_RESULT_PDF_KEY = 'flatten_result_pdf'
  ROTATE_INCREMENTAL_PDF_KEY = 'rotate_incremental_pdf'
  WITH_SIGNATURE_ID = 'with_signature_id'
  WITH_FILE_LINKS_KEY = 'with_file_links'
  WITH_SIGNATURE_ID_REASON_KEY = 'with_signature_id_reason'
  WITH_SIGNATURE_ID_COMPLETED_AT_KEY = 'with_signature_id_completed_at'
  RECIPIENT_FORM_FIELDS_KEY = 'recipient_form_fields'
  WITH_AUDIT_VALUES_KEY = 'with_audit_values'
  WITH_AUDIT_SENDER_KEY = 'with_audit_sender'
  WITH_SUBMITTER_TIMEZONE_KEY = 'with_submitter_timezone'
  WITH_TIMESTAMP_SECONDS_KEY = 'with_timestamp_seconds'
  REQUIRE_SIGNING_REASON_KEY = 'require_signing_reason'
  REUSE_SIGNATURE_KEY = 'reuse_signature'
  WITH_FIELD_LABELS_KEY = 'with_field_labels'
  COMBINE_PDF_RESULT_KEY = 'combine_pdf_result_key'
  DOCUMENT_FILENAME_FORMAT_KEY = 'document_filename_format'
  TEMPLATE_CUSTOM_FIELDS_KEY = 'template_custom_fields'
  TEMPLATE_DATE_FORMATS_KEY = 'template_date_formats'
  TEMPLATE_BUILDER_AUTOSAVE_KEY = 'template_builder_autosave'
  POLICY_LINKS_KEY = 'policy_links'
  ENABLE_MCP_KEY = 'enable_mcp'

  # StevensED: variables offered by the email template editor, matching what ReplaceEmailVariables replaces for
  # each email. The signing link is not offered: the branded frame always adds the action button.
  EMAIL_VARIABLES = {
    SUBMITTER_INVITATION_EMAIL_KEY => %w[document.name submitter.name submitter.first_name requester.name
                                         requester.office submission.expire_at account.name].freeze,
    SUBMITTER_VIEW_INVITATION_EMAIL_KEY => %w[document.name submitter.name submitter.first_name requester.name
                                              requester.office account.name].freeze,
    SUBMITTER_COMPLETED_EMAIL_KEY => %w[document.name submission.submitters requester.name requester.office
                                        account.name].freeze,
    SUBMITTER_INVITATION_REMINDER_EMAIL_KEY => %w[document.name submitter.name submitter.first_name requester.name
                                                  requester.office submission.expire_at account.name].freeze,
    SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY => %w[document.name submitter.name submitter.first_name submission.submitters
                                             requester.name requester.office account.name].freeze
  }.freeze

  # StevensED: an unsaved email shows the StevensED text (stevensed.email.*), not the DocuSeal defaults.
  DEFAULT_VALUES = [
    SUBMITTER_INVITATION_EMAIL_KEY,
    SUBMITTER_VIEW_INVITATION_EMAIL_KEY,
    SUBMITTER_INVITATION_REMINDER_EMAIL_KEY,
    SUBMITTER_COMPLETED_EMAIL_KEY,
    SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY
  ].index_with { |key| -> { Stevensed::EmailParts.all_defaults(key) } }.freeze

  belongs_to :account

  serialize :value, coder: JSON
end
