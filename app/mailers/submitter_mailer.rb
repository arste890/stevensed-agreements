# frozen_string_literal: true

class SubmitterMailer < ApplicationMailer
  MAX_ATTACHMENTS_SIZE = 10.megabytes
  # StevensED: signed download links in copy emails stay valid for 7 days (upstream: 80 minutes).
  SIGN_TTL = 7.days

  NO_REPLY_REGEXP = /no-?reply@/i
  STEVENSED_SUBJECT_PREFIX = 'StevensED: '

  # StevensED: the subject, heading, introduction and closing note come from Stevensed::EmailParts (per-send
  # message, then template role, template, account, StevensED defaults); the rest of each email is fixed in
  # the views. See lib/stevensed/email_parts.rb for the precedence and the legacy free-form bodies.
  def invitation_email(submitter, reminder: false)
    @current_account = submitter.submission.account
    @submitter = submitter
    @reminder = reminder

    if submitter.preferences['email_message_uuid']
      @email_message = submitter.account.email_messages.find_by(uuid: submitter.preferences['email_message_uuid'])
    end

    key = reminder ? AccountConfig::SUBMITTER_INVITATION_REMINDER_EMAIL_KEY : AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY

    @email_config = AccountConfigs.find_for_account(@current_account, key)
    @email_config ||= AccountConfigs.find_for_account(@current_account, AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY)

    assign_message_metadata('submitter_invitation', @submitter)

    reply_to = build_submitter_reply_to(@submitter, email_config: @email_config)

    maybe_set_custom_domain(@submitter)

    I18n.with_locale(@current_account.locale) do
      assign_email_parts(key, @email_message)

      subject = ReplaceEmailVariables.call(@email_parts.subject, submitter:)
      subject = build_reminder_subject(subject) if reminder && @email_parts.subject_from_message

      mail(
        to: @submitter.friendly_name,
        from: from_address_for_submitter(submitter),
        subject:,
        reply_to:,
        template_name: 'invitation_email'
      )
    end
  end

  def invitation_view_email(submitter)
    @current_account = submitter.submission.account
    @submitter = submitter

    if submitter.preferences['email_message_uuid']
      @email_message = submitter.account.email_messages.find_by(uuid: submitter.preferences['email_message_uuid'])
    end

    @email_config = AccountConfigs.find_for_account(@current_account, AccountConfig::SUBMITTER_VIEW_INVITATION_EMAIL_KEY)

    assign_message_metadata('submitter_view_invitation', @submitter)

    reply_to = build_submitter_reply_to(@submitter, email_config: @email_config)

    maybe_set_custom_domain(@submitter)

    I18n.with_locale(@current_account.locale) do
      assign_email_parts(AccountConfig::SUBMITTER_VIEW_INVITATION_EMAIL_KEY, @email_message)

      mail(
        to: @submitter.friendly_name,
        from: from_address_for_submitter(submitter),
        subject: ReplaceEmailVariables.call(@email_parts.subject, submitter:),
        reply_to:
      )
    end
  end

  def completed_email(submitter, user, to: nil)
    @current_account = submitter.submission.account
    @submitter = submitter
    @submission = submitter.submission
    @user = user

    template_preferences = @submission.template&.preferences || {}

    @email_config = AccountConfigs.find_for_account(@current_account, AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY)

    add_completed_email_attachments!(
      submitter,
      with_documents: @email_config&.value&.dig('attach_documents') != false &&
                      template_preferences['completed_notification_email_attach_documents'] != false,
      with_audit_log: @email_config&.value&.dig('attach_audit_log') != false &&
                      template_preferences['completed_notification_email_attach_audit'] != false
    )

    assign_message_metadata('submitter_completed', @submitter)

    I18n.with_locale(@current_account.locale) do
      assign_email_parts(AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY)

      mail(from: from_address_for_submitter(submitter),
           to: to || normalize_user_email(user),
           subject: ReplaceEmailVariables.call(@email_parts.subject, submitter:))
    end
  end

  def declined_email(submitter, user)
    @current_account = submitter.submission.account
    @submitter = submitter
    @submission = submitter.submission
    @user = user

    assign_message_metadata('submitter_declined', @submitter)

    I18n.with_locale(@current_account.locale) do
      mail(from: from_address_for_submitter(submitter),
           to: user.role == 'integration' ? user.friendly_name.sub(/\+\w+@/, '@') : user.friendly_name,
           reply_to: @submitter.friendly_name,
           subject: I18n.t('stevensed.email.declined_subject',
                           name: (@submission.name || @submission.template&.name).to_s.truncate(40),
                           submitter: @submitter.name || @submitter.email || @submitter.phone))
    end
  end

  def documents_copy_email(submitter, to: nil, sig: false)
    @current_account = submitter.submission.account
    @submitter = submitter
    @sig = submitter.signed_id(expires_in: SIGN_TTL, purpose: :download_completed) if sig

    template_preferences = @submitter.template&.preferences || {}

    @email_config = AccountConfigs.find_for_account(@current_account, AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY)

    add_completed_email_attachments!(
      submitter,
      with_documents: template_preferences['documents_copy_email_attach_documents'] != false &&
                      (@email_config.nil? || @email_config.value['attach_documents'] != false),
      with_audit_log: template_preferences['documents_copy_email_attach_audit'] != false &&
                      (@email_config.nil? || @email_config.value['attach_audit_log'] != false)
    )

    assign_message_metadata('submitter_documents_copy', @submitter)
    reply_to = build_submitter_reply_to(submitter, email_config: @email_config, documents_copy_email: true)

    maybe_set_custom_domain(@submitter)

    I18n.with_locale(@current_account.locale) do
      assign_email_parts(AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY)

      mail(from: from_address_for_submitter(submitter),
           to: to || @submitter.friendly_name,
           reply_to:,
           subject: ReplaceEmailVariables.call(@email_parts.subject, submitter:))
    end
  end

  def otp_verification_email(submitter, locale: nil)
    @current_account = submitter.account
    @submitter = submitter
    @otp_code = OtpChallenges.generate([submitter.email.downcase.squish, submitter.slug].join(':'),
                                       purpose: 'form_email_2fa')

    assign_message_metadata('otp_verification_email', submitter)

    from =
      if Docuseal.multitenant? &&
         AccountConfig.exists?(account_id: submitter.account_id, key: 'custom_otp_email', value: true)
        from_address_for_submitter(submitter)
      else
        default_params[:from]
      end

    I18n.with_locale(locale || submitter.account.locale) do
      mail(to: submitter.email, from:, subject: I18n.t('stevensed.email.otp_subject'))
    end
  end

  private

  # @body is the legacy free-form body (rendered in place of the frame); @email_parts holds the parts.
  def assign_email_parts(key, email_message = nil)
    @email_parts = Stevensed::EmailParts.resolve(key, @submitter, email_message:,
                                                                  preview: params.to_h[:email_preview])
    @body = @email_parts.legacy_body
  end

  def email_preview?
    params.to_h[:email_preview].present?
  end

  def build_submitter_reply_to(submitter, email_config: nil, documents_copy_email: nil)
    reply_to = submitter.preferences['reply_to'].presence
    reply_to ||= submitter.template&.preferences&.dig('documents_copy_email_reply_to').presence if documents_copy_email
    reply_to ||= email_config.value['reply_to'].presence if email_config

    # StevensED: replies go to the office mailbox, never to the sending staff member's personal address.
    reply_to ||= Stevensed::CONTACT_EMAIL

    return nil if reply_to.to_s.match?(NO_REPLY_REGEXP)

    reply_to
  end

  # StevensED: completion emails attach the completed document and the audit log as separate PDFs (never the
  # combined PDF). If together they exceed the size limit, nothing is attached and the email's links are the way in.
  def add_completed_email_attachments!(submitter, with_audit_log: true, with_documents: true)
    # StevensED: previews and test sends of the editor use sample data and attach nothing.
    return [] if email_preview?

    documents = with_documents ? select_completed_documents(submitter) : []
    audit_trail = (submitter.submission.audit_trail if with_audit_log && submitter.submission.audit_trail.present?)

    filename_format = AccountConfig.find_or_initialize_by(account_id: submitter.account_id,
                                                          key: AccountConfig::DOCUMENT_FILENAME_FORMAT_KEY)&.value

    files = [*documents, audit_trail].compact

    return [] if files.sum(&:byte_size) >= MAX_ATTACHMENTS_SIZE

    files.each do |attachment|
      filename = Submitters.build_document_filename(submitter, attachment.blob, filename_format)
      attachments[filename.to_s.tr('"', "'")] = attachment.download
    end

    @stevensed_attached = [('document' if documents.any?), ('audit' if audit_trail)].compact.join('_and_').presence

    total_size = files.sum(&:byte_size)

    if with_documents
      file_fields = submitter.submission.template_fields.select { |e| e['type'].in?(%w[file payment]) }

      if file_fields.pluck('submitter_uuid').uniq.size == 1
        storage_attachments =
          submitter.attachments.where(uuid: submitter.values.values_at(*file_fields.pluck('uuid')).flatten)

        add_attachments_with_size_limit(submitter, storage_attachments, total_size)
      end
    end

    documents
  end

  def normalize_user_email(user)
    user.role == 'integration' ? user.friendly_name.sub(/\+\w+@/, '@') : user.friendly_name
  end

  def build_reminder_subject(subject)
    Stevensed::EmailParts.reminder_subject(subject)
  end

  def select_completed_documents(submitter)
    last_submitter = Submitter.where(submission_id: submitter.submission_id).completed.order(:completed_at).last

    Submissions::EnsureResultGenerated.call(last_submitter)

    Submitters.select_attachments_for_download(last_submitter)
  end

  def add_attachments_with_size_limit(submitter, storage_attachments, current_size, filename_format = nil)
    total_size = current_size

    storage_attachments.each do |attachment|
      total_size += attachment.byte_size

      break if total_size >= MAX_ATTACHMENTS_SIZE

      filename = Submitters.build_document_filename(submitter, attachment.blob, filename_format)
      attachments[filename.to_s.tr('"', "'")] = attachment.download
    end

    total_size
  end

  def from_address_for_submitter(submitter)
    if submitter.submission.source.in?(%w[api embed]) &&
       (from_email = AccountConfig.find_by(account: submitter.account, key: 'integration_from_email')&.value.presence)
      user = submitter.account.users.find_by(email: from_email)

      put_metadata('from_user_id' => user.id)

      from_email
    else
      user = submitter.submission.created_by_user || submitter.submission.template.author

      put_metadata('from_user_id' => user.id)

      # StevensED: From shows the "Send as" requester at the office address, never a personal address.
      Stevensed::Requesters.from_address(Stevensed::Requesters.for_submission(submitter.submission))
    end
  end

  def maybe_set_custom_domain(submitter)
    if Docuseal.multitenant? && (config = AccountConfig.find_by(account_id: submitter.account_id, key: :custom_domain))
      @custom_domain = config.value
    end
  end
end
