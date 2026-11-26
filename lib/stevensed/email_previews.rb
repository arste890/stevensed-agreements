# frozen_string_literal: true

module Stevensed
  # StevensED: preview and test send for the email template editor.
  #
  # Renders the real SubmitterMailer views with sample records created inside a transaction that is always
  # rolled back, so nothing is stored. The editor's unsaved text is passed to the mailer as the 'email_preview'
  # param (see Stevensed::EmailParts.preview_levels). A test send goes only to the signed-in user.
  module EmailPreviews
    TEST_SUBJECT_PREFIX = '[Test] '
    SAMPLE_RECIPIENT_NAME = 'Jordan Rivera'
    SAMPLE_RECIPIENT_EMAIL = 'jordan.rivera@example.org'

    module_function

    # Returns the built Mail::Message (not delivered).
    def build(key:, user:, parts:, scope: 'account', variant: nil, template: nil)
      raise ArgumentError, "Unknown email: #{key}" unless Stevensed::EmailParts::KEYS.include?(key)

      variants = Stevensed::EmailParts.variants(key)
      variant = variants.first unless variants.include?(variant)
      preview = { scope: scope.to_s == 'template' ? 'template' : 'account', parts: parts.to_h }

      message = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        submitter = create_sample!(key:, user:, variant:, template:)
        mailer = SubmitterMailer.with(email_preview: preview)

        message =
          case key
          when Stevensed::EmailParts::INVITATION then mailer.invitation_email(submitter).message
          when Stevensed::EmailParts::REMINDER then mailer.invitation_email(submitter, reminder: true).message
          when Stevensed::EmailParts::VIEW then mailer.invitation_view_email(submitter).message
          when Stevensed::EmailParts::COMPLETED then mailer.completed_email(submitter, user).message
          when Stevensed::EmailParts::COPY then mailer.documents_copy_email(submitter).message
          end

        raise ActiveRecord::Rollback
      end

      message
    end

    def html(message)
      (message.html_part || message).body.decoded
    end

    # Sends the preview to the signed-in user only: recipients, copies and tracking metadata are removed.
    def deliver_test(message, user)
      message.to = user.email
      message.cc = nil
      message.bcc = nil
      message.subject = "#{TEST_SUBJECT_PREFIX}#{message.subject}"
      message.instance_variable_set(:@message_metadata, {})

      message.deliver

      message
    end

    def create_sample!(key:, user:, variant:, template:)
      account = user.account
      uuid = SecureRandom.uuid
      completed = key.in?([Stevensed::EmailParts::COMPLETED, Stevensed::EmailParts::COPY])

      fields = []

      if variant != 'submit'
        fields << { 'uuid' => SecureRandom.uuid, 'submitter_uuid' => uuid, 'type' => 'signature',
                    'name' => 'Signature', 'required' => true, 'areas' => [] }
      end

      party_name = template&.submitters.to_a.first&.dig('name') || 'First Party'

      submission = Submission.create!(
        account:,
        created_by_user: user,
        name: template&.name.presence || I18n.t('stevensed.email_templates.sample_document'),
        template_fields: fields,
        template_schema: [],
        template_submitters: [{ 'uuid' => uuid, 'name' => party_name,
                                'is_viewer' => key == Stevensed::EmailParts::VIEW }],
        expire_at: 14.days.from_now,
        source: 'invite'
      )

      Submitter.create!(submission:, account:, uuid:, name: SAMPLE_RECIPIENT_NAME, email: SAMPLE_RECIPIENT_EMAIL,
                        completed_at: (Time.current if completed))
    end
  end
end
