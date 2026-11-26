# frozen_string_literal: true

module Submissions
  # StevensED: the audit log follows the institutional layout used by StevensED email (navy band with the
  # reverse lockup, coral rule, Cormorant Garamond headings and Inter text). The data it records is unchanged
  # from upstream; the layout adds a signing certificate summary and a footer with page numbers.
  module GenerateAuditTrail
    FONT_SIZE = 8.5
    FONT_PATH = '/fonts/GoNotoKurrent-Regular.ttf'
    FONT_BOLD_PATH = '/fonts/GoNotoKurrent-Bold.ttf'
    FALLBACK_FONT_NAME = File.exist?(FONT_PATH) ? 'GoNotoKurrent' : nil

    BRAND_FONTS_DIR = Rails.root.join('lib/stevensed/fonts')
    SANS = 'Inter'
    SERIF = 'Cormorant Garamond'
    FONT_NAME = SANS
    LOCKUP_PATH = Rails.root.join('lib/stevensed/pdf/lockup-reverse.pdf')

    # StevensED palette (see tailwind.config.js and the mailer layout).
    INK = '1F2948'
    NAVY = '2F3E68'
    CORAL = 'C13F44'
    MUTED = '5B6478'
    BAND_MUTED = 'C9D0DE'
    RULE = 'D8D0C1'
    PANEL = 'F7F5F1'
    TEXT_COLOR = INK

    MARGIN_X = 54
    BAND_HEIGHT = 84
    CORAL_RULE_HEIGHT = 4
    FOOTER_HEIGHT = 44

    CURRENCY_SYMBOLS = {
      'USD' => '$',
      'EUR' => '€',
      'GBP' => '£'
    }.freeze

    TESTING_FOOTER = GenerateResultAttachments::TESTING_FOOTER
    UNSUPPORTED_IMAGE_TYPES = GenerateResultAttachments::UNSUPPORTED_IMAGE_TYPES

    RTL_REGEXP = TextUtils::RTL_REGEXP
    MAX_IMAGE_HEIGHT = 100

    CHECKSUM_LIMIT = 30

    US_TIMEZONES = TimeUtils::US_TIMEZONES

    module_function

    # rubocop:disable Metrics
    def call(submission)
      account = submission.account

      last_submitter = submission.submitters.select(&:completed_at).max_by(&:completed_at)

      I18n.with_locale(last_submitter.metadata.fetch('lang', account.locale)) do
        document = build_audit_trail(submission)

        pkcs = Accounts.load_signing_pkcs(account)
        tsa_url = Accounts.load_timeserver_url(account)

        io = StringIO.new

        document.trailer.info[:Creator] = "#{Docuseal.product_name} (#{Stevensed::WEBSITE_URL})"

        if pkcs
          sign_params = {
            reason: sign_reason,
            **Submissions::GenerateResultAttachments.build_signing_params(last_submitter, pkcs, tsa_url)
          }

          document.sign(io, **sign_params)

          Submissions::GenerateResultAttachments.maybe_enable_ltv(io, sign_params)
        else
          document.write(io)
        end

        ActiveStorage::Attachment.create!(
          blob: ActiveStorage::Blob.create_and_upload!(
            io: io.tap(&:rewind), filename: "#{I18n.t('audit_log')} - " \
                                            "#{submission.name || submission.template&.name}.pdf".tr('/', '-')
          ),
          name: 'audit_trail',
          record: submission
        )
      end
    end

    def build_audit_trail(submission)
      account = submission.account

      page_size = Stevensed.page_size(account)

      composer = HexaPDF::Composer.new(skip_page_creation: true)

      if Docuseal.pdf_format == 'pdf/a-3b'
        composer.document.task(:pdfa, level: '3b')
      else
        composer.document.task(:pdfa)
      end

      configure_fonts(composer.document)

      configs = submission.account.account_configs.where(key: [AccountConfig::WITH_AUDIT_VALUES_KEY,
                                                               AccountConfig::WITH_SIGNATURE_ID,
                                                               AccountConfig::WITH_FILE_LINKS_KEY,
                                                               AccountConfig::WITH_TIMESTAMP_SECONDS_KEY,
                                                               AccountConfig::WITH_AUDIT_SENDER_KEY,
                                                               AccountConfig::WITH_SUBMITTER_TIMEZONE_KEY])

      last_submitter = submission.submitters.select(&:completed_at).max_by(&:completed_at)

      with_signature_id = configs.find { |c| c.key == AccountConfig::WITH_SIGNATURE_ID }&.value == true
      with_file_links = configs.find { |c| c.key == AccountConfig::WITH_FILE_LINKS_KEY }&.value == true
      with_audit_values = configs.find { |c| c.key == AccountConfig::WITH_AUDIT_VALUES_KEY }&.value != false
      with_audit_sender = configs.find { |c| c.key == AccountConfig::WITH_AUDIT_SENDER_KEY }&.value == true
      with_submitter_timezone = configs.find { |c| c.key == AccountConfig::WITH_SUBMITTER_TIMEZONE_KEY }&.value == true
      with_timestamp_seconds = configs.find { |c| c.key == AccountConfig::WITH_TIMESTAMP_SECONDS_KEY }&.value == true

      file_links_expire_at = Accounts.link_expires_at(submission.account) if with_file_links

      timezone = account.timezone
      timezone = last_submitter.timezone || account.timezone if with_submitter_timezone

      lockup = load_lockup(composer.document)

      composer.page_style(:first, page_size:, next_style: :default) do |canvas, style|
        draw_band(canvas, composer.document, lockup)

        style.frame = style.create_frame(canvas.context, [BAND_HEIGHT + CORAL_RULE_HEIGHT + 26, MARGIN_X,
                                                          FOOTER_HEIGHT + 14, MARGIN_X])
      end

      composer.page_style(:default, page_size:) do |canvas, style|
        style.frame = style.create_frame(canvas.context, [MARGIN_X, MARGIN_X, FOOTER_HEIGHT + 14, MARGIN_X])
      end

      composer.style(:base, font: SANS, font_size: FONT_SIZE, fill_color: INK, line_spacing: 1.35)
      composer.style(:link, fill_color: NAVY, underline: true)
      composer.style(:label, font: [SANS, { variant: :bold }], fill_color: MUTED)
      composer.style(:eyebrow, font: [SANS, { variant: :bold }], font_size: 6.5, fill_color: MUTED,
                               character_spacing: 0.7)
      composer.style(:section, font: [SERIF, { variant: :bold }], font_size: 15, fill_color: INK,
                               padding: [16, 0, 4, 0])

      composer.new_page(:first)

      completed_at = last_submitter&.completed_at

      composer.text(account.testing? ? I18n.t('testing_log_not_for_production_use') : I18n.t('audit_log'),
                    font: [SERIF, { variant: :bold }], font_size: 26, fill_color: INK, padding: [0, 0, 8, 0])

      summary_rows = [
        [I18n.t('envelope_id'), submission.id.to_s],
        [t(:document), TextUtils.maybe_rtl_reverse((submission.name || submission.template&.name).to_s)],
        completed_at && [t(:completed), format_time(completed_at, timezone, :long)],
        [t(:issued_by), "#{Stevensed::LEGAL_ENTITY}, #{Stevensed::OFFICE}"]
      ].compact

      if show_verify?(submission)
        summary_rows << [I18n.t('verify'), { link: Stevensed::PKI_URL, text: Stevensed::PKI_URL.delete_suffix('/'),
                                             style: :link }]
      end

      composer.table(
        summary_rows.map do |label, value|
          [composer.document.layout.text_box(label.to_s.upcase, style: :eyebrow, padding: [2, 0, 0, 0]),
           composer.document.layout.formatted_text_box([value])]
        end,
        column_widths: [110, -1],
        cell_style: { padding: [0, 0, 5, 0], border: { width: 0 } }
      )

      documents_data = select_attachments(last_submitter).map do |document|
        original_documents = submission.schema_documents.select do |e|
          e.uuid == (document.metadata['original_uuid'] || document.uuid)
        end.presence

        original_documents ||= submission.template.documents.select do |e|
          e.image? && submission.template_schema.any? do |item|
            item['attachment_uuid'] == e.uuid
          end
        end

        [
          composer.document.layout.formatted_text_box(
            [{ text: TextUtils.maybe_rtl_reverse(document.filename.to_s), font: [SANS, { variant: :bold }] }],
            padding: [0, 12, 0, 0]
          ),
          composer.document.layout.formatted_text_box(
            [
              { text: "#{I18n.t('original_sha256')}\n", style: :eyebrow },
              { text: original_documents.map { |d| d.metadata['sha256'] || d.checksum }
                                        .first(CHECKSUM_LIMIT).join("\n"), font_size: 7.5 },
              "\n",
              { text: "#{I18n.t('result_sha256')}\n", style: :eyebrow },
              { text: (document.metadata['sha256'] || document.checksum).to_s, font_size: 7.5 },
              "\n",
              { text: "#{I18n.t('generated_at')}\n", style: :eyebrow },
              format_time(document.created_at, timezone, :long)
            ], line_spacing: 1.4
          )
        ]
      end

      if documents_data.present?
        section_heading(composer, t(:documents))
        composer.table(documents_data, column_widths: [170, -1],
                                       cell_style: { padding: [0, 0, 14, 0], border: { width: 0 } })
      end

      section_heading(composer, t(:signers))

      submission.template_submitters.filter_map do |item|
        submitter = submission.submitters.find { |e| e.uuid == item['uuid'] }

        next if submitter.blank?

        submission_events = submission.submission_events.select { |e| e.submitter_id == submitter.id }

        delegated_event = submission_events.select(&:delegate_form?).max_by(&:event_timestamp)

        if delegated_event
          submission_events = submission_events.select { |e| e.event_timestamp > delegated_event.event_timestamp }
        end

        completed_event = submission_events.find(&:complete_form?) || SubmissionEvent.new

        click_email_event = submission_events.find(&:click_email?)

        verify_email_event = submission_events.find(&:email_verified?)

        verify_phone_event = submission_events.find(&:phone_verified?)

        esign_consent_event = submission_events.find(&:accept_esign_consent?)

        is_id_verified = submission_events.any?(&:complete_verification?)

        complete_kba_event = submission_events.find(&:complete_kba?) || SubmissionEvent.new

        kba_answers = complete_kba_event.data['answers']
        kba_score = " (#{kba_answers['correct']}/#{kba_answers['asked']})" if kba_answers

        detail = lambda do |label, value|
          [{ text: "#{label}: ", style: :label }, { text: "#{value}\n" }]
        end

        identity_box = composer.document.layout.formatted_text_box(
          [
            { text: "#{TextUtils.maybe_rtl_reverse(item['name'].to_s).upcase}\n", style: :eyebrow,
              fill_color: CORAL },
            submitter.name && { text: "#{TextUtils.maybe_rtl_reverse(submitter.name.squish)}\n",
                                font: [SANS, { variant: :bold }], font_size: 10 },
            submitter.email && { text: "#{submitter.email.squish}\n" },
            submitter.phone && { text: "#{submitter.phone.squish}\n" },
            submitter.completed_at && { text: "#{t(:completed)} " \
                                              "#{format_time(submitter.completed_at, timezone, :long)}\n",
                                        fill_color: MUTED }
          ].compact_blank, line_spacing: 1.4, padding: [0, 14, 0, 0]
        )

        details_box = composer.document.layout.formatted_text_box(
          [
            submitter.viewer? && { text: "#{I18n.t('view_only')}\n" },
            *(submitter.email && (click_email_event || verify_email_event) &&
              detail.call(I18n.t('email_verification'), I18n.t('verified'))),
            *(submitter.phone && verify_phone_event && detail.call(I18n.t('phone_verification'), I18n.t('verified'))),
            *(is_id_verified && detail.call(I18n.t('identity_verification'), I18n.t('verified'))),
            *(complete_kba_event.persisted? &&
              detail.call(I18n.t('knowledge_based_authentication'), "#{I18n.t('passed')}#{kba_score}")),
            esign_consent_event && { text: Stevensed::Consents.audit_line(esign_consent_event) },
            *(completed_event.data['ip'] && detail.call(t(:ip_address), completed_event.data['ip'])),
            *(completed_event.data['sid'] && detail.call(I18n.t('session_id'), completed_event.data['sid'])),
            *(completed_event.data['ua'] && detail.call(t(:user_agent), completed_event.data['ua'].to_s.squish)),
            *(submitter.timezone && detail.call(t(:time_zone), submitter.timezone.to_s.sub('Kiev', 'Kyiv')))
          ].compact_blank, line_spacing: 1.4
        )

        composer.table(
          [[identity_box, details_box]],
          column_widths: [170, -1],
          cell_style: { padding: [10, 12, 8, 12], background_color: PANEL,
                        border: { width: [0, 0, 0, 2], color: NAVY } },
          margin: [0, 0, 10, 0]
        )

        submitter_field_counters = Hash.new { 0 }
        grouped_value_field_names = {}
        skip_grouped_field_uuids = {}

        submission.template_fields.each do |field|
          next unless field['type'].in?(%w[signature initials])

          submitter_field_counters[field['type']] += 1

          next if field['submitter_uuid'] != submitter.uuid

          value = submitter.values[field['uuid']]

          field_name = field['title'].presence || field['name'].presence ||
                       "#{I18n.t("#{field['type']}_field")} #{submitter_field_counters[field['type']]}"

          if grouped_value_field_names[value]
            skip_grouped_field_uuids[field['uuid']] = true

            grouped_value_field_names[value] += ", #{field_name}"
          else
            grouped_value_field_names[value] = field_name
          end
        end

        submitter_field_counters = Hash.new { 0 }

        submission.template_fields.filter_map do |field|
          submitter_field_counters[field['type']] += 1

          next if field['submitter_uuid'] != submitter.uuid
          next if field['type'] == 'heading' || field['type'] == 'strikethrough'
          next if !with_audit_values && !field['type'].in?(%w[signature initials])
          next if skip_grouped_field_uuids[field['uuid']]

          value = submitter.values[field['uuid']]

          next if Array.wrap(value).compact_blank.blank?

          field_name = grouped_value_field_names[value].presence || field['title'].presence || field['name'].to_s

          field_type = field['type']

          if (field_type == 'image' || field_type == 'stamp') &&
             submitter.attachments.find { |a| a.uuid == value }
                      .then { |a| !a.image? || a.content_type.in?(UNSUPPORTED_IMAGE_TYPES) }
            field_type = 'file'
          end

          [
            composer.formatted_text_box(
              [
                {
                  text: TextUtils.maybe_rtl_reverse(field_name).upcase.presence ||
                        "#{I18n.t("#{field['type']}_field")} #{submitter_field_counters[field['type']]}".upcase,
                  style: :eyebrow
                }
              ].compact_blank,
              text_align: field_name.to_s.match?(RTL_REGEXP) ? :right : :left,
              line_spacing: 1.3, padding: [0, 0, 2, 12]
            ),
            if field_type.in?(%w[image signature initials stamp kba]) &&
               (attachment = submitter.attachments.find { |a| a.uuid == value }) &&
               attachment.image?

              image =
                begin
                  ImageUtils.load_vips(attachment.download, content_type: attachment.content_type, autorot: true)
                rescue Vips::Error
                  next unless attachment.content_type.starts_with?('image/')
                  next if attachment.byte_size.zero?

                  raise
                end

              scale = [600.0 / image.width, 600.0 / image.height].min

              resized_image = image.resize([scale, 1].min)

              io =
                if field['type'] == 'image' && !resized_image.has_alpha?
                  StringIO.new(resized_image.colourspace(:srgb).write_to_buffer('.jpg', strip: true))
                else
                  StringIO.new(resized_image.write_to_buffer('.png', strip: true))
                end

              width = field['type'] == 'initials' ? 50 : 200
              height = resized_image.height * (width.to_f / resized_image.width)

              if height > MAX_IMAGE_HEIGHT
                width = (MAX_IMAGE_HEIGHT / height) * width
                height = MAX_IMAGE_HEIGHT
              end

              if with_signature_id && field['type'].in?(%w[signature initials])
                composer.image(io, width:, height:, margin: [4, 0, 2, 12])
                composer.formatted_text_box([{ text: "ID #{attachment.uuid.upcase}", style: :eyebrow }],
                                            padding: [0, 0, 10, 12])
              else
                composer.image(io, width:, height:, margin: [4, 0, 10, 12])
                composer.formatted_text_box([{ text: '' }])
              end
            elsif field_type.in?(%w[file payment image])
              if field['type'] == 'payment'
                unit = CURRENCY_SYMBOLS[field['preferences']['currency']] || field['preferences']['currency']

                price = ApplicationController.helpers.number_to_currency(field['preferences']['price'], unit:)

                composer.formatted_text_box([{ text: "#{I18n.t('paid_price', price:)}\n" }],
                                            padding: [0, 0, 10, 12])
              end

              composer.formatted_text_box(
                Array.wrap(value).map do |uuid|
                  attachment = submitter.attachments.find { |a| a.uuid == uuid }

                  link =
                    if with_file_links
                      ActiveStorage::Blob.proxy_url(attachment.blob, expires_at: file_links_expire_at)
                    else
                      r.submissions_preview_url(submission.slug, **Docuseal.default_url_options)
                    end

                  { link:, text: "#{TextUtils.maybe_rtl_reverse(attachment.filename.to_s)}\n", style: :link }
                end,
                padding: [0, 0, 10, 12]
              )
            elsif field_type == 'checkbox'
              composer.formatted_text_box([{ text: value.to_s.titleize }], padding: [0, 0, 10, 12])
            else
              if field['type'] == 'date'
                value = TimeUtils.format_date_string(value, field.dig('preferences', 'format'), I18n.locale,
                                                     timezone:)
              end

              value = NumberUtils.format_number(value, field.dig('preferences', 'format')) if field['type'] == 'number'

              value = value.join(', ') if value.is_a?(Array)

              if (mask = field.dig('preferences', 'mask').presence)
                value = TextUtils.mask_value(value, mask)
              end

              composer.formatted_text_box([{ text: TextUtils.maybe_rtl_reverse(value.to_s.presence || 'n/a') }],
                                          text_align: value.to_s.match?(RTL_REGEXP) ? :right : :left,
                                          padding: [0, 0, 10, 12])
            end
          ]
        end

        composer.formatted_text_box([{ text: '' }], margin: [0, 0, 8, 0])
      end

      submitter_versions_index = submission.submitters.preload(:submitter_versions).to_h do |s|
        [s.id, s.submitter_versions.to_a.sort_by(&:created_at)]
      end

      events_data = submission.submission_events.sort_by(&:event_timestamp).filter_map do |event|
        next if event.event_type.in?(%w[bounce_email complaint_email fail_sms])

        submitter = submission.submitters.find { |e| e.id == event.submitter_id }
        versions = submitter_versions_index[submitter.id] || []
        active_version = versions.find { |v| v.created_at > event.event_timestamp }

        submitter_name =
          if event.event_type.include?('sms') || event.event_type.include?('phone')
            event.data['phone'] || active_version&.phone || submitter.phone
          else
            active_version&.name || active_version&.email || active_version&.phone ||
              submitter.name || submitter.email || submitter.phone
          end

        submitter_name = TextUtils.maybe_rtl_reverse(submitter_name.to_s.squish)

        text =
          if event.event_type == 'complete_verification'
            identity_name = [event.data['firstname'], event.data['lastname']].compact_blank.join(' ')
            identity_name = TextUtils.maybe_rtl_reverse(identity_name) if identity_name.present?

            I18n.t('submission_event_names.complete_verification_by_html',
                   provider: event.data['method'], submitter_name: identity_name.presence || submitter_name)
          elsif event.event_type == 'invite_party' &&
                (invited_submitter = submission.submitters.find { |e| e.uuid == event.data['uuid'] }) &&
                (name = submission.template_submitters.find { |e| e['uuid'] == event.data['uuid'] }&.dig('name'))
            invited_submitter_name = TextUtils.maybe_rtl_reverse(
              [invited_submitter.name || invited_submitter.email || invited_submitter.phone, name].join(' ').squish
            )
            I18n.t('submission_event_names.invite_party_by_html', invited_submitter_name:,
                                                                  submitter_name:)
          elsif with_audit_sender && (event.event_type == 'send_email' || event.event_type == 'send_sms')
            created_by_name = TextUtils.maybe_rtl_reverse(submission.created_by_user.full_name.to_s.squish)

            [
              I18n.t("submission_event_names.#{event.event_type}_to_html", submitter_name:),
              "<b>#{I18n.t(:from)}</b> #{created_by_name} #{submission.created_by_user.email}"
            ].join("\n")
          elsif event.event_type == 'delegate_form'
            from = event.data['old_email'].presence ||
                   versions.rfind { |v| v.created_at <= event.event_timestamp }&.then { |v| v.name || v.phone }
            from = TextUtils.maybe_rtl_reverse(from.to_s.squish)
            I18n.t('submission_event_names.delegate_form_by_html', from:, to: event.data['email'].to_s.squish)
          elsif event.event_type.include?('send_')
            I18n.t("submission_event_names.#{event.event_type}_to_html", submitter_name:)
          else
            I18n.t("submission_event_names.#{event.event_type}_by_html", submitter_name:)
          end

        bold_text, normal_text = text.match(%r{<b>(.*?)</b>(.*)}).captures

        text_box = [{ text: bold_text, font: [SANS, { variant: :bold }] }, normal_text]

        if text.include?("\n")
          text_box = text.split("\n")[1..].reduce(text_box) do |acc, row|
            bold_text, normal_text = row.match(%r{<b>(.*?)</b>(.*)}).captures

            [*acc, "\n", { text: bold_text, font: [SANS, { variant: :bold }] }, normal_text]
          end
        end

        time_format = with_timestamp_seconds ? :detailed : :long

        [
          composer.document.layout.text_box(format_time(event.event_timestamp, timezone, time_format),
                                            fill_color: MUTED),
          composer.document.layout.formatted_text_box(text_box)
        ]
      end

      if events_data.present?
        section_heading(composer, I18n.t('event_log'))

        header_cell = lambda do |text|
          { content: composer.document.layout.text_box(text.upcase, style: :eyebrow, fill_color: 'FFFFFF'),
            background_color: NAVY, padding: [5, 8, 4, 8] }
        end

        composer.table(
          events_data,
          column_widths: [170, -1],
          header: ->(_table) { [[header_cell.call(t(:time)), header_cell.call(t(:event))]] },
          cell_style: lambda do |cell|
            cell.style.update(padding: [5, 8, 4, 8], border: { width: [0, 0, 0.5, 0], color: RULE })
            cell.style.update(background_color: PANEL) if cell.row.odd?
          end
        )
      end

      add_certificate_summary(composer, account, timezone)

      add_footers(composer.document, submission, with_signature_id)

      composer.document
    end

    def section_heading(composer, title)
      composer.text(title, style: :section)
      composer.draw_box(HexaPDF::Layout::Box.create(height: 0.75, margin: [0, 0, 10, 0],
                                                    border: { width: [0.75, 0, 0, 0], color: RULE }))
    end

    def configure_fonts(document)
      sans = { none: BRAND_FONTS_DIR.join('Inter-Regular.ttf').to_s,
               bold: BRAND_FONTS_DIR.join('Inter-SemiBold.ttf').to_s }

      font_map = {
        SANS => sans,
        # PDF/A embeds every font, so anything that asks for Helvetica (such as the signature field) gets Inter.
        'Helvetica' => sans,
        SERIF => {
          none: BRAND_FONTS_DIR.join('CormorantGaramond-Medium.ttf').to_s,
          bold: BRAND_FONTS_DIR.join('CormorantGaramond-SemiBold.ttf').to_s
        }
      }

      if FALLBACK_FONT_NAME
        font_map[FALLBACK_FONT_NAME] = { none: FONT_PATH, bold: FONT_BOLD_PATH }

        # Inter and Cormorant cover Latin, Greek and Cyrillic; names and values in other scripts are set in
        # Go Noto Kurrent glyph by glyph.
        document.config['font.fallback'] = [FALLBACK_FONT_NAME]
      else
        document.config['font.on_missing_glyph'] =
          Submissions::GenerateResultAttachments.method(:on_missing_glyph).to_proc
      end

      document.config['font.map'] = font_map
    end

    def load_lockup(document)
      source = HexaPDF::Document.open(LOCKUP_PATH.to_s)

      document.import(source.add(source.pages[0].to_form_xobject(reference: false)))
    end

    def draw_band(canvas, document, lockup)
      box = canvas.context.box(:media)
      band_bottom = box.height - BAND_HEIGHT

      canvas.save_graphics_state do
        canvas.fill_color(NAVY).rectangle(0, band_bottom, box.width, BAND_HEIGHT).fill
        canvas.fill_color(CORAL).rectangle(0, band_bottom - CORAL_RULE_HEIGHT, box.width, CORAL_RULE_HEIGHT).fill
      end

      lockup_height = 50
      lockup_width = lockup.box.width * (lockup_height / lockup.box.height)
      canvas.xobject(lockup, at: [MARGIN_X, band_bottom + ((BAND_HEIGHT - lockup_height) / 2.0)],
                             width: lockup_width, height: lockup_height)

      text_width = box.width - (MARGIN_X * 2) - lockup_width - 20

      heading = document.layout.formatted_text_box(
        [
          { text: "#{Stevensed::PRODUCT_NAME}\n", font: [SERIF, { variant: :bold }], font_size: 20,
            fill_color: 'FFFFFF' },
          { text: Stevensed::OFFICE.upcase, font: SANS, font_size: 6.5, fill_color: BAND_MUTED, character_spacing: 0.9 }
        ], text_align: :right, line_spacing: 1.5
      )

      draw_text_box(canvas, heading, box.width - MARGIN_X - text_width, band_bottom + 20, text_width, BAND_HEIGHT - 34)
    end

    def draw_text_box(canvas, text_box, left, bottom, width, height)
      frame = HexaPDF::Layout::Frame.new(left, bottom, width, height, context: canvas.context)
      result = frame.fit(text_box)

      frame.draw(canvas, result) if result.success?
    end

    def add_certificate_summary(composer, account, timezone)
      # The summary is informational: an account without a signing certificate gets a log without it.
      pkcs = begin
        Accounts.load_signing_pkcs(account)
      rescue NoMethodError, OpenSSL::OpenSSLError
        nil
      end
      certificate = pkcs&.certificate

      return if certificate.blank?

      tsa_url = Accounts.load_timeserver_url(account)
      tsa_host = (URI.parse(tsa_url).host if tsa_url.present?) rescue nil # rubocop:disable Style/RescueModifier

      name_part = ->(name, key) { name.to_a.find { |e| e[0] == key }&.second }
      chain = Array.wrap(pkcs.try(:ca_certs))
      root = chain.last unless chain.last == certificate

      rows = [
        [t(:signed_by), [name_part.call(certificate.subject, 'CN'),
                         name_part.call(certificate.subject, 'O')].compact.join(', ')],
        [t(:certificate_issuer), name_part.call(certificate.issuer, 'CN') || certificate.issuer.to_s],
        root && [t(:root_certificate), name_part.call(root.subject, 'CN') || root.subject.to_s],
        [t(:serial_number), certificate.serial.to_s(16).upcase],
        [t(:valid), "#{format_time(certificate.not_before, timezone, :long)} to " \
                    "#{format_time(certificate.not_after, timezone, :long)}"],
        [t(:sha256_fingerprint), OpenSSL::Digest::SHA256.hexdigest(certificate.to_der).upcase.scan(/../)
                                                      .each_slice(16).map { |bytes| bytes.join(':') }.join(":\n")],
        tsa_host && [t(:time_stamp_authority), tsa_host]
      ].compact

      section_heading(composer, t(:signing_certificate))

      composer.table(
        rows.map do |label, value|
          [composer.document.layout.text_box(label.to_s.upcase, style: :eyebrow, padding: [2, 0, 0, 0]),
           composer.document.layout.text_box(value.to_s)]
        end,
        column_widths: [130, -1],
        cell_style: { padding: [0, 0, 5, 0], border: { width: 0 } }
      )

      composer.formatted_text(
        ["#{t(:verification)} ", { link: Stevensed::PKI_URL, text: Stevensed::PKI_URL.delete_suffix('/'),
                                   style: :link }, '.'],
        fill_color: MUTED, padding: [6, 0, 0, 0]
      )
    end

    def add_footers(document, submission, with_signature_id)
      pages = document.pages.to_a
      envelope = "#{I18n.t('envelope_id')} #{submission.id}"

      left_text =
        if submission.account.testing?
          TESTING_FOOTER
        else
          "#{Stevensed::LEGAL_ENTITY} · #{Stevensed::OFFICE} · #{Docuseal.default_url_options[:host]}"
        end

      if with_signature_id
        left_text = "#{left_text}\n#{I18n.t('document_id')} #{Digest::MD5.hexdigest(submission.slug).upcase}"
      end

      pages.each_with_index do |page, index|
        canvas = page.canvas(type: :overlay)
        box = page.box(:media)
        width = box.width - (MARGIN_X * 2)

        canvas.save_graphics_state do
          canvas.stroke_color(RULE).line_width(0.75)
                .line(MARGIN_X, FOOTER_HEIGHT, box.width - MARGIN_X, FOOTER_HEIGHT).stroke
        end

        page_label = t(:page_number_of_total, number: index + 1, total: pages.size)

        draw_text_box(canvas, document.layout.text_box(left_text, font: SANS, font_size: 6.5, fill_color: MUTED),
                      MARGIN_X, 18, width * 0.72, FOOTER_HEIGHT - 24)
        draw_text_box(canvas, document.layout.text_box("#{envelope} · #{page_label}", font: SANS, font_size: 6.5,
                                                                                      fill_color: MUTED,
                                                                                      text_align: :right),
                      MARGIN_X + (width * 0.72), 18, width * 0.28, FOOTER_HEIGHT - 24)
      end
    end

    def t(key, **)
      I18n.t(key, scope: 'stevensed.audit_log', **)
    end

    def format_time(time, timezone, format)
      "#{I18n.l(time.in_time_zone(timezone), format:)} #{TimeUtils.timezone_abbr(timezone, time)}"
    end

    def sign_reason
      Stevensed::SIGN_REASON
    end

    def select_attachments(submitter)
      original_documents = submitter.submission.schema_documents.preload(:blob)
      is_more_than_two_images = original_documents.many?(&:image?)

      submitter.documents.preload(:blob).reject do |attachment|
        is_more_than_two_images &&
          original_documents.find { |a| a.uuid == (attachment.metadata['original_uuid'] || attachment.uuid) }&.image?
      end
    end

    def maybe_add_background(_canvas, _submission, _page_size); end

    def show_verify?(submission)
      !submission.source.in?(%w[embed api])
    end

    def r
      Rails.application.routes.url_helpers
    end
    # rubocop:enable Metrics
  end
end
