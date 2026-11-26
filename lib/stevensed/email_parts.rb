# frozen_string_literal: true

module Stevensed
  # StevensED: the editable text of the five branded emails sent to recipients and staff.
  #
  # Each email is built from a fixed frame (letterhead, details table, action button, e-signature statement,
  # contact line, personal link notice, footer) and four editable parts: subject, heading, introduction and an
  # optional closing note. Only the parts are stored; the frame stays in app/views/submitter_mailer.
  #
  # Where the parts are stored:
  #   account:  AccountConfig value for the email's key, e.g. { 'subject' => ..., 'intro' => ... }
  #   template: template.preferences['email_parts'][key]
  #   role:     template.preferences['email_parts_by_submitter'][submitter_uuid] (signature request only)
  #
  # Precedence, highest first, resolved part by part (a blank part falls through to the next level):
  #   1. per-send message from the Send dialog (EmailMessage subject, body as the introduction)
  #   2. template parts for the recipient's role
  #   3. template parts
  #   4. account parts
  #   5. StevensED defaults (stevensed.email.* in config/locales/stevensed.yml)
  #
  # The signature request and the reminder have two versions: 'sign' for recipients with signature fields and
  # 'submit' for forms without them. The subject, heading and introduction are stored for each version (the
  # 'submit' ones with a '_submit' suffix); the closing note is shared.
  #
  # Legacy: a free-form body saved before this editor ('body' at account level, the template '*_body'
  # preferences, a per-send message that contains the signing link variable) still replaces the frame as it
  # did before, unless a level above it holds structured parts. New saves always use the parts.
  module EmailParts
    INVITATION = AccountConfig::SUBMITTER_INVITATION_EMAIL_KEY
    VIEW = AccountConfig::SUBMITTER_VIEW_INVITATION_EMAIL_KEY
    REMINDER = AccountConfig::SUBMITTER_INVITATION_REMINDER_EMAIL_KEY
    COMPLETED = AccountConfig::SUBMITTER_COMPLETED_EMAIL_KEY
    COPY = AccountConfig::SUBMITTER_DOCUMENTS_COPY_EMAIL_KEY

    KEYS = [INVITATION, VIEW, REMINDER, COMPLETED, COPY].freeze

    PARTS = %w[subject heading intro closing].freeze
    VARIANT_PARTS = %w[subject heading intro].freeze
    VARIANTS = { INVITATION => %w[sign submit], REMINDER => %w[sign submit] }.freeze

    FIELDS = (PARTS + VARIANT_PARTS.map { |part| "#{part}_submit" }).freeze

    # Template preferences used before this editor: [subject, body].
    LEGACY_TEMPLATE_KEYS = {
      INVITATION => %w[request_email_subject request_email_body],
      VIEW => %w[invitation_view_email_subject invitation_view_email_body],
      REMINDER => %w[invitation_reminder_email_subject invitation_reminder_email_body],
      COMPLETED => %w[completed_notification_email_subject completed_notification_email_body],
      COPY => %w[documents_copy_email_subject documents_copy_email_body]
    }.freeze

    LEGACY_ACCOUNT_KEYS = %w[body body_type html_body].freeze

    DOCUMENT_TOKEN = '{document.name}'
    SIGNATURE_FIELD_TYPES = %w[signature initials].freeze

    Result = Struct.new(:key, :variant, :parts, :legacy_body, :subject_from_message, keyword_init: true) do
      def legacy?
        legacy_body.present?
      end

      def subject
        parts['subject']
      end
    end

    module_function

    def variants(key)
      VARIANTS.fetch(key, [nil])
    end

    def fields_for(key)
      variants(key).flat_map { |variant| VARIANT_PARTS.map { |part| field_name(part, variant) } }.uniq + ['closing']
    end

    def field_name(part, variant)
      variant == 'submit' && VARIANT_PARTS.include?(part) ? "#{part}_submit" : part
    end

    def variant_for(key, submitter)
      return unless VARIANTS.key?(key)

      submitter.with_signature_fields? ? 'sign' : 'submit'
    end

    def variant_for_template(key, template, submitter_uuid)
      return unless VARIANTS.key?(key)

      return 'sign' unless template

      uuid = submitter_uuid || template.submitters.to_a.first&.dig('uuid')
      fields = template.fields.to_a.select { |f| f['submitter_uuid'] == uuid }

      fields.any? { |f| SIGNATURE_FIELD_TYPES.include?(f['type']) } ? 'sign' : 'submit'
    end

    # StevensED defaults for one version, as editor text: i18n %{name} becomes the {document.name} variable.
    def defaults(key, variant = nil)
      sign = variant != 'submit'
      action = sign ? 'sign' : 'submit'

      parts =
        case key
        when INVITATION, REMINDER
          subject = I18n.t(sign ? 'stevensed.invite_subject' : 'stevensed.email.submit_subject', name: DOCUMENT_TOKEN)

          {
            'subject' => key == REMINDER ? reminder_subject(subject) : subject,
            'heading' => I18n.t("stevensed.email.invitation_title_#{action}", name: DOCUMENT_TOKEN),
            'intro' => I18n.t("stevensed.email.#{key == REMINDER ? 'reminder' : 'invitation'}_intro_#{action}")
          }
        when VIEW
          { 'subject' => I18n.t('stevensed.email.view_subject', name: DOCUMENT_TOKEN),
            'heading' => I18n.t('stevensed.email.view_title', name: DOCUMENT_TOKEN),
            'intro' => I18n.t('stevensed.email.view_intro') }
        when COMPLETED
          { 'subject' => I18n.t('stevensed.email.completed_subject').gsub('{submission.name}', DOCUMENT_TOKEN),
            'heading' => I18n.t('stevensed.email.completed_title', name: DOCUMENT_TOKEN),
            'intro' => I18n.t('stevensed.email.completed_intro') }
        when COPY
          { 'subject' => I18n.t('stevensed.email.copy_subject', name: DOCUMENT_TOKEN),
            'heading' => I18n.t('stevensed.email.copy_title', name: DOCUMENT_TOKEN),
            'intro' => I18n.t('stevensed.email.copy_intro') }
        else
          raise ArgumentError, "Unknown email: #{key}"
        end

      parts.merge('closing' => '')
    end

    # Defaults for every stored field of an email (both versions where there are two).
    def all_defaults(key)
      variants(key).each_with_object({}) do |variant, acc|
        defaults(key, variant).each { |part, value| acc[field_name(part, variant)] ||= value }
      end
    end

    # "StevensED: please review..." becomes "StevensED reminder: please review...".
    def reminder_subject(subject)
      prefix = SubmitterMailer::STEVENSED_SUBJECT_PREFIX

      if subject.start_with?(prefix)
        "#{I18n.t('stevensed.reminder_subject_prefix')} #{subject.delete_prefix(prefix)}"
      else
        "#{I18n.t('stevensed.reminder_prefix')} #{subject}"
      end
    end

    def resolve(key, submitter, email_message: nil, preview: nil)
      resolve_for(key,
                  account: submitter.submission.account,
                  template: submitter.submission.template,
                  submitter_uuid: submitter.uuid,
                  variant: variant_for(key, submitter),
                  email_message:,
                  preview:)
    end

    def resolve_for(key, account:, template:, submitter_uuid: nil, variant: nil, email_message: nil, preview: nil)
      levels = preview ? preview_levels(key, account, preview) : stored_levels(key, account, template, submitter_uuid)
      levels.unshift(message_level(email_message)) if email_message && !preview

      parts = {}
      subject_from_message = false

      levels.each do |level|
        if level[:legacy_body].present? && parts.except('subject').empty?
          if parts['subject'].nil? && (legacy_subject = level[:parts]['subject'].presence)
            parts['subject'] = legacy_subject
            subject_from_message = level[:message].present?
          end

          return Result.new(key:, variant:, parts: defaults(key, variant).merge(parts),
                            legacy_body: level[:legacy_body], subject_from_message:)
        end

        PARTS.each do |part|
          next if parts[part]

          value = level[:parts][field_name(part, variant)].presence
          next unless value

          parts[part] = value
          subject_from_message = true if part == 'subject' && level[:message]
        end
      end

      Result.new(key:, variant:, parts: defaults(key, variant).merge(parts), legacy_body: nil, subject_from_message:)
    end

    # Values the editor shows for a level: saved parts over everything below it.
    def effective_fields(key, account:, template: nil, submitter_uuid: nil, scope: :account)
      fields = all_defaults(key)
      fields = fields.merge(account_parts(key, account)) if scope != :defaults
      fields = fields.merge(template_parts(key, template)) if template && scope.in?(%i[template role])
      fields = fields.merge(role_parts(key, template, submitter_uuid)) if template && scope == :role

      fields
    end

    def account_parts(key, account)
      value = AccountConfigs.find_for_account(account, key)&.value

      value.is_a?(Hash) ? value.slice(*FIELDS).compact_blank : {}
    end

    def template_parts(key, template)
      parts = template&.preferences&.dig('email_parts', key)
      parts = parts.is_a?(Hash) ? parts.slice(*FIELDS).compact_blank : {}

      legacy_subject = template&.preferences&.dig(LEGACY_TEMPLATE_KEYS[key].first).presence
      parts['subject'] ||= legacy_subject if legacy_subject

      parts
    end

    def role_parts(key, template, submitter_uuid)
      return {} unless key == INVITATION && submitter_uuid

      parts = template&.preferences&.dig('email_parts_by_submitter', submitter_uuid)
      parts = parts.is_a?(Hash) ? parts.slice(*FIELDS).compact_blank : {}

      legacy = legacy_role(template, submitter_uuid)
      parts['subject'] ||= legacy['request_email_subject'] if legacy['request_email_subject'].present?

      parts
    end

    def legacy_account_body(key, account)
      value = AccountConfigs.find_for_account(account, key)&.value

      value.is_a?(Hash) ? value['body'].presence : nil
    end

    def legacy_template_body(key, template)
      template&.preferences&.dig(LEGACY_TEMPLATE_KEYS[key].last).presence
    end

    def legacy_role(template, submitter_uuid)
      template&.preferences&.dig('submitters').to_a.find { |e| e.is_a?(Hash) && e['uuid'] == submitter_uuid } || {}
    end

    def legacy?(key, account: nil, template: nil)
      return legacy_template_body(key, template).present? if template

      legacy_account_body(key, account).present?
    end

    def stored_levels(key, account, template, submitter_uuid)
      levels = []

      if key == INVITATION && template && submitter_uuid
        levels << { parts: role_parts(key, template, submitter_uuid),
                    legacy_body: legacy_role(template, submitter_uuid)['request_email_body'].presence }
      end

      levels << { parts: template_parts(key, template), legacy_body: legacy_template_body(key, template) } if template
      levels << { parts: account_parts(key, account), legacy_body: legacy_account_body(key, account) }

      levels
    end

    # Preview of unsaved editor text: the form replaces the level being edited; a blank part shows what the
    # level below gives (the account version for a template, the StevensED default for the account).
    def preview_levels(key, account, preview)
      levels = [{ parts: preview[:parts].to_h.stringify_keys.slice(*FIELDS) }]
      levels << { parts: account_parts(key, account) } if preview[:scope].to_s == 'template'

      levels
    end

    def message_level(email_message)
      body = email_message.normalized_body.to_s
      subject = email_message.subject.to_s

      if body.match?(ReplaceEmailVariables::SUBMITTER_LINK) || body.match?(ReplaceEmailVariables::SUBMISSION_LINK)
        return { parts: { 'subject' => subject, 'subject_submit' => subject }, legacy_body: body, message: true }
      end

      { parts: { 'subject' => subject, 'subject_submit' => subject, 'intro' => body, 'intro_submit' => body },
        message: true }
    end

    # Submitted editor fields without blanks and without values equal to what the level below already gives,
    # so an untouched editor keeps following the defaults (or the account version) when those change.
    def clean_fields(key, submitted, baseline)
      submitted.to_h.stringify_keys.slice(*fields_for(key)).each_with_object({}) do |(field, value), acc|
        value = value.to_s.strip.gsub("\r\n", "\n")

        next if value.blank?
        next if value.squish == baseline[field].to_s.squish

        acc[field] = value
      end
    end

    # Account level: replaces the parts in the AccountConfig value and drops a legacy free-form body.
    def clean_account_value(key, value)
      other = value.except(*FIELDS, *LEGACY_ACCOUNT_KEYS)

      other.merge(clean_fields(key, value.slice(*FIELDS), all_defaults(key)))
    end

    # Template level: stores the template parts (and per role parts for the signature request) and drops the
    # legacy free-form template preferences of that email.
    def apply_template_fields(template, key, submitted, by_submitter: nil)
      preferences = template.preferences
      account = template.account

      template_baseline = effective_fields(key, account:, scope: :account)
      fields = clean_fields(key, submitted, template_baseline)

      email_parts = preferences['email_parts'].is_a?(Hash) ? preferences['email_parts'].dup : {}
      fields.present? ? email_parts[key] = fields : email_parts.delete(key)
      email_parts.present? ? preferences['email_parts'] = email_parts : preferences.delete('email_parts')

      LEGACY_TEMPLATE_KEYS[key].each { |legacy_key| preferences.delete(legacy_key) }

      apply_role_fields(template, key, by_submitter, template_baseline.merge(fields)) if by_submitter

      template.preferences = preferences
    end

    def apply_role_fields(template, key, by_submitter, baseline)
      preferences = template.preferences
      uuids = template.submitters.pluck('uuid')

      roles = by_submitter.to_h.slice(*uuids).each_with_object({}) do |(uuid, submitted), acc|
        role_fields = clean_fields(key, submitted, baseline)
        acc[uuid] = role_fields if role_fields.present?
      end

      roles.present? ? preferences['email_parts_by_submitter'] = roles : preferences.delete('email_parts_by_submitter')
      preferences.delete('submitters')
    end

    def reset_template(template, key)
      preferences = template.preferences

      preferences['email_parts']&.delete(key)
      preferences.delete('email_parts') if preferences['email_parts'].blank?

      if key == INVITATION
        preferences.delete('email_parts_by_submitter')
        preferences.delete('submitters')
      end

      LEGACY_TEMPLATE_KEYS[key].each { |legacy_key| preferences.delete(legacy_key) }

      template.preferences = preferences
    end

    def template_customized?(template, key)
      template_parts(key, template).present? || legacy_template_body(key, template).present? ||
        (key == INVITATION && (template.preferences['email_parts_by_submitter'].present? ||
                               template.preferences['submitters'].present?))
    end

    # Subject and message the Send dialog starts from (the resolved introduction, or a legacy free-form body).
    def send_dialog_defaults(account:, template:, submitter_uuid: nil, viewer: false)
      key = viewer ? VIEW : INVITATION
      result = resolve_for(key, account:, template:, submitter_uuid:,
                                variant: variant_for_template(key, template, submitter_uuid))

      [result.subject, result.legacy_body.presence || result.parts['intro']]
    end

    def variables(key)
      AccountConfig::EMAIL_VARIABLES.fetch(key, [])
    end

    def variable_label(variable)
      I18n.t("stevensed.email_templates.variables.#{variable.tr('.', '_')}", default: "{#{variable}}")
    end
  end
end
