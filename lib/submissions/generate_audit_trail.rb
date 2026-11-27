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
    # Hashes, fingerprints and serial numbers are set in a monospaced face so that their characters line up.
    MONO = 'DejaVu Sans Mono'
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
    LABEL_CELL = 'F1EDE5'
    TEXT_COLOR = INK

    MARGIN_X = 54
    BAND_HEIGHT = 84
    CORAL_RULE_HEIGHT = 4
    FOOTER_HEIGHT = 44
    # Continuation pages carry a slim running header: a line of text above a hairline, mirroring the footer.
    HEADER_RULE_FROM_TOP = 38
    LABEL_COLUMN_WIDTH = 170
    DETAIL_LABEL_WIDTH = 104
    CELL_PADDING = [5, 8, 4, 8].freeze
    # Event log date and time columns, measured in Inter at body size with cell padding: "28 September 2026", and
    # "12:46 AM AKST" or, with seconds, "12:46:05 AM AKST", each on one line.
    EVENT_DATE_WIDTH = 98
    EVENT_TIME_WIDTH = 80
    EVENT_TIME_WITH_SECONDS_WIDTH = 93
    # Every rule in the log is one hairline in one colour.
    HAIRLINE = 0.5

    # One modular type scale (major second, 1.125) built on the 8.5 pt body size.
    TYPE = { label: -2, meta: -1, body: 0, name: 2, section: 5, band: 7, title: 9 }
           .transform_values { |step| (8.5 * (1.125**step)).round(2) }.freeze

    # Pagination: a table never opens or closes a page with fewer than this many rows (orphans and widows).
    MIN_ROWS = 3
    # When the last page would be less than this full, the log is set again with tighter vertical spacing and the
    # tighter version is kept if it saves the page.
    SPARSE_LAST_PAGE = 0.3
    COMPACT_RHYTHM = 0.7

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
      document, fill = compose_audit_trail(submission, rhythm: 1)

      if document.pages.count > 1 && fill < SPARSE_LAST_PAGE
        compact, = compose_audit_trail(submission, rhythm: COMPACT_RHYTHM)
        document = compact if compact.pages.count < document.pages.count
      end

      document
    end

    # Sets the log with vertical spacing scaled by rhythm. Returns the document and how full its last page is.
    def compose_audit_trail(submission, rhythm:)
      account = submission.account
      gap = ->(points) { (points * rhythm).round(2) }

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

      running_header = t(:running_header, product: Stevensed::PRODUCT_NAME, title: I18n.t('audit_log'),
                                          id: submission.id)

      composer.page_style(:default, page_size:) do |canvas, style|
        draw_running_header(canvas, composer.document, running_header)

        style.frame = style.create_frame(canvas.context, [MARGIN_X, MARGIN_X, FOOTER_HEIGHT + 14, MARGIN_X])
      end

      composer.style(:base, font: SANS, font_size: FONT_SIZE, fill_color: INK, line_spacing: 1.35)
      composer.style(:link, fill_color: NAVY, underline: true)
      composer.style(:label, font: [SANS, { variant: :bold }], fill_color: MUTED)
      composer.style(:eyebrow, font: [SANS, { variant: :bold }], font_size: TYPE[:label], fill_color: MUTED,
                               character_spacing: 0.7)
      composer.style(:hash, font: MONO, font_size: TYPE[:meta], fill_color: INK, line_spacing: 1.45)
      composer.style(:section, font: [SERIF, { variant: :bold }], font_size: TYPE[:section], fill_color: INK,
                               padding: [gap.call(18), 0, 4, 0])

      composer.new_page(:first)

      completed_at = last_submitter&.completed_at

      composer.text(account.testing? ? I18n.t('testing_log_not_for_production_use') : I18n.t('audit_log'),
                    font: [SERIF, { variant: :bold }], font_size: TYPE[:title], fill_color: INK,
                    padding: [0, 0, gap.call(8), 0])

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
          [label_box(composer.document.layout, label), composer.document.layout.formatted_text_box([value])]
        end,
        column_widths: [LABEL_COLUMN_WIDTH + CELL_PADDING[3], -1],
        cell_style: { padding: [0, 0, gap.call(5), 0], border: { width: 0 } }
      )

      documents_data = select_attachments(last_submitter).map do |document|
        original_documents = submission.schema_documents.select do |e|
          e.uuid == (document.metadata['original_uuid'] || document.uuid)
        end.presence

        original_documents ||= submission.template.documents.select do |e|
          e.image? && (submission.template_schema.presence || submission.template.schema).any? do |item|
            item['attachment_uuid'] == e.uuid
          end
        end

        [
          composer.document.layout.formatted_text_box(
            [{ text: TextUtils.maybe_rtl_reverse(document.filename.to_s), font: [SANS, { variant: :bold }] }]
          ),
          composer.document.layout.formatted_text_box(
            [
              { text: "#{I18n.t('original_sha256').upcase}\n", style: :eyebrow },
              { text: original_documents.map { |d| even_halves(d.metadata['sha256'] || d.checksum) }
                                        .first(CHECKSUM_LIMIT).join("\n"), style: :hash },
              "\n",
              { text: "#{I18n.t('result_sha256').upcase}\n", style: :eyebrow },
              { text: even_halves(document.metadata['sha256'] || document.checksum), style: :hash },
              "\n",
              { text: "#{I18n.t('generated_at').upcase}\n", style: :eyebrow },
              format_time(document.created_at, timezone, :long)
            ], line_spacing: 1.45
          )
        ]
      end

      if documents_data.present?
        draw_table(composer, documents_data, header: [t(:document), t(:detail)], label_column: true,
                                             lead: heading_boxes(composer, t(:documents)), margin: gap.call(4))
      end

      signers_heading = false

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

        detail = ->(label, value) { [[label, value]] }

        identity_box = composer.document.layout.formatted_text_box(
          [
            { text: "#{TextUtils.maybe_rtl_reverse(item['name'].to_s).upcase}\n", style: :eyebrow,
              fill_color: CORAL },
            (signer_name = Stevensed::SignerName.for(submitter)) &&
              { text: "#{TextUtils.maybe_rtl_reverse(signer_name.squish)}\n", font: [SANS, { variant: :bold }],
                font_size: TYPE[:name] },
            # A zero-width space after the @ lets a long address wrap there rather than mid-word.
            submitter.email && { text: "#{submitter.email.squish.sub('@', "@\u200B")}\n" },
            submitter.phone && { text: "#{submitter.phone.squish}\n" },
            submitter.completed_at && { text: "#{t(:completed)} " \
                                              "#{format_time(submitter.completed_at, timezone, :long)}\n",
                                        fill_color: MUTED }
          ].compact_blank, line_spacing: 1.4, padding: [0, 14, 0, 0]
        )

        # The consent record is one or more "Label: value" lines; each becomes a row like the other details.
        consent_rows =
          if esign_consent_event
            Stevensed::Consents.audit_line(esign_consent_event, timezone:).lines.map(&:strip).compact_blank
                                .map { |line| line.split(': ', 2) }
          end

        detail_rows = [
          *(submitter.viewer? && detail.call(t(:access), I18n.t('view_only'))),
          *(submitter.email && (click_email_event || verify_email_event) &&
            detail.call(I18n.t('email_verification'), I18n.t('verified'))),
          *(submitter.phone && verify_phone_event && detail.call(I18n.t('phone_verification'), I18n.t('verified'))),
          *(is_id_verified && detail.call(I18n.t('identity_verification'), I18n.t('verified'))),
          *(complete_kba_event.persisted? &&
            detail.call(I18n.t('knowledge_based_authentication'), "#{I18n.t('passed')}#{kba_score}")),
          *consent_rows,
          *(completed_event.data['ip'] && detail.call(t(:ip_address), completed_event.data['ip'])),
          *(completed_event.data['sid'] && detail.call(I18n.t('session_id'), completed_event.data['sid'])),
          *(completed_event.data['ua'] && detail.call(t(:user_agent), completed_event.data['ua'].to_s.squish)),
          *(submitter.timezone && detail.call(t(:time_zone), submitter.timezone.to_s.sub('Kiev', 'Kyiv')))
        ].grep(Array)

        details_box =
          if detail_rows.present?
            composer.document.layout.table_box(
              detail_rows.map do |label, value|
                if value.nil?
                  [{ content: composer.document.layout.text_box(label.to_s), col_span: 2 }]
                else
                  [label_box(composer.document.layout, label), composer.document.layout.text_box(value.to_s)]
                end
              end,
              column_widths: [DETAIL_LABEL_WIDTH, -1],
              cell_style: { padding: [0, 0, 4, 0], border: { width: 0 } }
            )
          else
            composer.document.layout.text_box('')
          end

        panel_box = composer.document.layout.table_box(
          [[identity_box, details_box]],
          column_widths: [LABEL_COLUMN_WIDTH, -1],
          cell_style: { padding: [10, 12, 8, 12], background_color: PANEL,
                        border: { width: [0, 0, 0, 2], color: NAVY } },
          margin: [0, 0, gap.call(10), 0]
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
        layout = composer.document.layout

        field_rows = submission.template_fields.filter_map do |field|
          submitter_field_counters[field['type']] += 1

          next if field['submitter_uuid'] != submitter.uuid
          next if field['type'] == 'heading' || field['type'] == 'strikethrough'
          next if !with_audit_values && !field['type'].in?(%w[signature initials])
          next if skip_grouped_field_uuids[field['uuid']]

          value = submitter.values[field['uuid']]

          next if Array.wrap(value).compact_blank.blank?

          field_name = grouped_value_field_names[value].presence || field['title'].presence || field['name'].to_s
          field_name = field_name.split(', ').map { |name| Stevensed::FieldLabel.display(name, role: item['name']) }
                                 .join(', ')

          field_type = field['type']

          if (field_type == 'image' || field_type == 'stamp') &&
             submitter.attachments.find { |a| a.uuid == value }
                      .then { |a| !a.image? || a.content_type.in?(UNSUPPORTED_IMAGE_TYPES) }
            field_type = 'file'
          end

          label = TextUtils.maybe_rtl_reverse(field_name).presence ||
                  "#{I18n.t("#{field['type']}_field")} #{submitter_field_counters[field['type']]}"

          [
            layout.text_box(label, text_align: label.match?(RTL_REGEXP) ? :right : :left),
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

              image_box = layout.image_box(io, width:, height:, margin: [2, 0, 2, 0])

              if with_signature_id && field['type'].in?(%w[signature initials])
                [image_box, layout.text_box("ID #{attachment.uuid.upcase}", style: :eyebrow)]
              else
                image_box
              end
            elsif field_type.in?(%w[file payment image])
              unit = CURRENCY_SYMBOLS[field.dig('preferences', 'currency')] || field.dig('preferences', 'currency')

              layout.formatted_text_box(
                [
                  field['type'] == 'payment' &&
                    { text: "#{I18n.t('paid_price', price: ApplicationController.helpers.number_to_currency(
                      field['preferences']['price'], unit:
                    ))}\n" },
                  *Array.wrap(value).map do |uuid|
                    attachment = submitter.attachments.find { |a| a.uuid == uuid }

                    link =
                      if with_file_links
                        ActiveStorage::Blob.proxy_url(attachment.blob, expires_at: file_links_expire_at)
                      else
                        r.submissions_preview_url(submission.slug, **Docuseal.default_url_options)
                      end

                    { link:, text: "#{TextUtils.maybe_rtl_reverse(attachment.filename.to_s)}\n", style: :link }
                  end
                ].compact_blank
              )
            elsif field_type == 'checkbox'
              layout.text_box(ActiveModel::Type::Boolean.new.cast(value) ? t(:yes) : t(:no))
            else
              value = format_date(value, field, timezone) if field['type'] == 'date'

              value = NumberUtils.format_number(value, field.dig('preferences', 'format')) if field['type'] == 'number'

              value = value.join(', ') if value.is_a?(Array)

              if (mask = field.dig('preferences', 'mask').presence)
                value = TextUtils.mask_value(value, mask)
              end

              layout.text_box(TextUtils.maybe_rtl_reverse(value.to_s.presence || 'n/a'),
                              text_align: value.to_s.match?(RTL_REGEXP) ? :right : :left)
            end
          ]
        end

        # The signer's card stays with the first rows of the signer's entries (and the Signers heading with the
        # first card); longer lists continue on the next page under a repeated header row.
        lead = [*(heading_boxes(composer, t(:signers)) unless signers_heading), panel_box]
        signers_heading = true

        if field_rows.present?
          draw_table(composer, field_rows, header: [t(:field), t(:entry)], label_column: true, lead:,
                                           margin: gap.call(18))
        else
          keep_together(composer, lead)
          lead.each { |box| composer.draw_box(box) }
        end
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
              Stevensed::SignerName.for(submitter) || submitter.email || submitter.phone
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

        date, time = format_time(event.event_timestamp, timezone, time_format).split(', ', 2)

        [
          composer.document.layout.text_box(date, fill_color: MUTED),
          composer.document.layout.text_box(time.to_s, fill_color: MUTED, text_align: :right),
          composer.document.layout.formatted_text_box(text_box)
        ]
      end

      if events_data.present?
        # Date and time sit in their own columns so that times line up, right-aligned on the minute.
        time_width = with_timestamp_seconds ? EVENT_TIME_WITH_SECONDS_WIDTH : EVENT_TIME_WIDTH

        draw_table(composer, events_data, header: [t(:date), t(:time), t(:event)], banded: true,
                                          column_widths: [EVENT_DATE_WIDTH, time_width, -1],
                                          lead: heading_boxes(composer, I18n.t('event_log')), margin: gap.call(18))
      end

      add_certificate_summary(composer, account, timezone)

      frame = composer.frame
      fill = 1 - (frame.available_height / frame.height)

      add_footers(composer.document, submission, with_signature_id)

      [composer.document, fill]
    end

    # A section heading and its hairline, kept with whatever is drawn after them.
    def heading_boxes(composer, title)
      [composer.document.layout.text_box(title, style: :section),
       HexaPDF::Layout::Box.create(height: HAIRLINE, margin: [0, 0, 10, 0],
                                   border: { width: [HAIRLINE, 0, 0, 0], color: RULE })]
    end

    # Draws a table page by page instead of letting it split anywhere. Rows never split; the navy header row
    # repeats on every page; a page never opens or closes with fewer than MIN_ROWS rows (a shorter table moves
    # whole); and the lead boxes (section heading, signer card) stay with the first rows.
    def draw_table(composer, rows, header:, lead: [], column_widths: [LABEL_COLUMN_WIDTH, -1], label_column: false,
                   banded: false, margin: 0)
      layout = composer.document.layout
      header_boxes = header.map { |text| layout.text_box(text.upcase, style: :eyebrow, fill_color: 'FFFFFF') }
      backgrounds = rows.each_index.map do |index|
        rows[index].each_index.map do |column|
          (LABEL_CELL if label_column && column.zero?) || (PANEL if banded && index.odd?)
        end
      end
      # HexaPDF takes cell hashes apart when it builds a table, so every table gets fresh ones.
      table = lambda do |indexes, with_header: true, bottom: 0|
        part = indexes.map do |index|
          rows[index].zip(backgrounds[index]).map do |cell, background|
            background ? { content: cell, background_color: background } : cell
          end
        end
        header_row = header_boxes.map { |box| { content: box, background_color: NAVY, padding: CELL_PADDING } }

        layout.table_box(part, column_widths: column_widths.dup, header: (->(_t) { [header_row] } if with_header),
                               cell_style: { padding: CELL_PADDING,
                                             border: { width: [0, 0, HAIRLINE, 0], color: RULE } },
                               margin: [0, 0, bottom, 0])
      end

      heights = rows.each_index.map { |index| measure(composer, table.call([index], with_header: false)) }
      header_height = measure(composer, table.call([0])) - heights.first
      lead_height = lead.sum { |box| measure(composer, box) }

      index = 0

      while index < rows.size
        room = composer.frame.available_height - header_height - (index.zero? ? lead_height : 0)
        fit = 0
        total = 0
        heights[index..].each do |height|
          break if total + height > room

          total += height
          fit += 1
        end
        remaining = rows.size - index

        if fit < remaining
          fit = remaining - MIN_ROWS if remaining - fit < MIN_ROWS
          fresh = composer.frame.available_height >= composer.frame.height - 1

          if fit < [MIN_ROWS, remaining].min && !fresh
            composer.new_page
            next
          end

          fit = fit.clamp(1, remaining)
        end

        lead.each { |box| composer.draw_box(box) } if index.zero?
        composer.draw_box(table.call((index...(index + fit)).to_a, bottom: index + fit == rows.size ? margin : 0))
        index += fit
        composer.new_page if index < rows.size
      end
    end

    def measure(composer, box)
      frame = composer.frame
      probe = HexaPDF::Layout::Frame.new(0, 0, frame.width, 100_000, context: frame.context)
      probe.fit(box)

      box.height + box.style.margin.top + box.style.margin.bottom
    end

    def configure_fonts(document)
      sans = { none: BRAND_FONTS_DIR.join('Inter-Regular.ttf').to_s,
               bold: BRAND_FONTS_DIR.join('Inter-SemiBold.ttf').to_s }

      font_map = {
        SANS => sans,
        # PDF/A embeds every font, so anything that asks for Helvetica (such as the signature field) gets Inter.
        'Helvetica' => sans,
        MONO => { none: BRAND_FONTS_DIR.join('DejaVuSansMono.ttf').to_s },
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
          { text: "#{Stevensed::PRODUCT_NAME}\n", font: [SERIF, { variant: :bold }], font_size: TYPE[:band],
            fill_color: 'FFFFFF' },
          { text: Stevensed::OFFICE.upcase, font: SANS, font_size: TYPE[:label], fill_color: BAND_MUTED, character_spacing: 0.9 }
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
        [t(:serial_number), hex_bytes(certificate.serial.to_s(16)), :hash],
        [t(:valid), "#{Stevensed.format_date(certificate.not_before.in_time_zone(timezone))} to " \
                    "#{Stevensed.format_date(certificate.not_after.in_time_zone(timezone))}"],
        [t(:sha256_fingerprint), hex_bytes(OpenSSL::Digest::SHA256.hexdigest(certificate.to_der)), :hash],
        tsa_host && [t(:time_stamp_authority), tsa_host]
      ].compact

      layout = composer.document.layout
      note = layout.formatted_text_box(
        ["#{t(:verification)} ", { link: Stevensed::PKI_URL, text: Stevensed::PKI_URL.delete_suffix('/'),
                                   style: :link, font_size: TYPE[:meta] }, '.'],
        fill_color: MUTED, font_size: TYPE[:meta]
      )

      table = layout.table_box(
        [
          *rows.map do |label, value, style|
            [label_box(layout, label), style ? layout.text_box(value.to_s, style:) : layout.text_box(value.to_s)]
          end,
          [{ content: note, col_span: 2 }]
        ],
        column_widths: [LABEL_COLUMN_WIDTH, -1],
        header: ->(_table) { [[header_cell(layout, t(:certificate)), header_cell(layout, t(:detail))]] },
        cell_style: lambda do |cell|
          cell.style.update(padding: CELL_PADDING, border: { width: [0, 0, HAIRLINE, 0], color: RULE })
          if cell.col_span > 1
            cell.style.update(background_color: PANEL, padding: [7, 8, 6, 8], border: { width: 0 })
          elsif cell.column.zero?
            cell.style.update(background_color: LABEL_CELL)
          end
        end,
        margin: [0, 0, 4, 0]
      )

      boxes = [*heading_boxes(composer, t(:signing_certificate)), table]
      keep_together(composer, boxes)
      boxes.each { |box| composer.draw_box(box) }
    end

    def header_cell(layout, text)
      { content: layout.text_box(text.upcase, style: :eyebrow, fill_color: 'FFFFFF'), background_color: NAVY,
        padding: CELL_PADDING }
    end

    # Labels throughout the log are set the same way: small tracked capitals in the muted colour.
    def label_box(layout, text)
      layout.text_box(text.to_s.upcase, style: :eyebrow, padding: [2, 0, 0, 0])
    end

    # A hexadecimal value as colon-separated bytes, in two even halves.
    def hex_bytes(hex)
      hex = hex.to_s.upcase
      even_halves((hex.length.odd? ? "0#{hex}" : hex).scan(/../).join(':'))
    end

    # Splits a long hash into two lines of equal length: whole bytes when the value is colon-separated,
    # otherwise characters.
    def even_halves(value)
      value = value.to_s

      return value if value.length < 32

      if value.include?(':')
        bytes = value.split(':')
        half = (bytes.size / 2.0).ceil

        "#{bytes[0...half].join(':')}:\n#{bytes[half..].join(':')}"
      else
        half = (value.length / 2.0).ceil

        "#{value[0...half]}\n#{value[half..]}"
      end
    end

    def draw_running_header(canvas, document, text)
      box = canvas.context.box(:media)
      rule_y = box.height - HEADER_RULE_FROM_TOP

      canvas.save_graphics_state do
        canvas.stroke_color(RULE).line_width(HAIRLINE).line(MARGIN_X, rule_y, box.width - MARGIN_X, rule_y).stroke
      end

      draw_text_box(canvas, document.layout.text_box(text, font: SANS, font_size: TYPE[:label], fill_color: MUTED),
                    MARGIN_X, rule_y + 5, box.width - (MARGIN_X * 2), 14)
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
          canvas.stroke_color(RULE).line_width(HAIRLINE)
                .line(MARGIN_X, FOOTER_HEIGHT, box.width - MARGIN_X, FOOTER_HEIGHT).stroke
        end

        page_label = t(:page_number_of_total, number: index + 1, total: pages.size)

        footer_style = { font: SANS, font_size: TYPE[:label], fill_color: MUTED }

        draw_text_box(canvas, document.layout.text_box(left_text, **footer_style),
                      MARGIN_X, 18, width * 0.72, FOOTER_HEIGHT - 24)
        draw_text_box(canvas, document.layout.text_box("#{envelope} · #{page_label}", **footer_style,
                                                                                      text_align: :right),
                      MARGIN_X + (width * 0.72), 18, width * 0.28, FOOTER_HEIGHT - 24)
      end
    end

    def t(key, **)
      I18n.t(key, scope: 'stevensed.audit_log', **)
    end

    def format_time(time, timezone, format)
      Stevensed.format_datetime(time, timezone, seconds: format == :detailed)
    end

    def format_date(value, field, timezone)
      Stevensed.format_date(Date.iso8601(value.to_s))
    rescue Date::Error
      TimeUtils.format_date_string(value, field.dig('preferences', 'format'), I18n.locale, timezone:)
    end

    # Starts a new page when the boxes do not fit in what is left of this page but would fit on an empty one.
    def keep_together(composer, boxes, extra: 0)
      frame = composer.frame
      height = extra + boxes.sum do |box|
        probe = HexaPDF::Layout::Frame.new(0, 0, frame.width, 100_000, context: frame.context)
        probe.fit(box).then { box.height + box.style.margin.top + box.style.margin.bottom }
      end

      composer.new_page if height > frame.available_height && height <= frame.height
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
