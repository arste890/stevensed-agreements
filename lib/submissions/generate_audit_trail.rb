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
    LABEL_COLUMN_WIDTH = 178
    CELL_PADDING = [5, 8, 4, 8].freeze
    # Every rule in the log is one hairline in one colour.
    HAIRLINE = 0.75

    # One modular type scale (major second, 1.125) built on the 8.5 pt body size.
    TYPE = { label: -2, meta: -1, body: 0, name: 2, section: 5, band: 7, title: 9 }
           .transform_values { |step| (8.5 * (1.125**step)).round(2) }.freeze

    # Pagination: a table never opens or closes a page with fewer than this many rows (orphans and widows).
    MIN_ROWS = 4
    # DejaVu Sans Mono has a larger x-height than Inter; at this size the two read as the same size.
    MONO_SIZE = 8.1
    # Sets monospaced values on the same baseline as the Inter labels beside them.
    MONO_BASELINE_SHIFT = 0.9
    EVENT_TIME_WIDTH = 132
    # When the last page would be less than this full, the log is set again with tighter vertical spacing and the
    # tighter version is kept if it saves the page.
    SPARSE_LAST_PAGE = 0.4
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
      cell_padding = [gap.call(CELL_PADDING[0]), CELL_PADDING[1], gap.call(CELL_PADDING[2]), CELL_PADDING[3]]

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

      file_links_expire_at = Accounts.link_expires_at(submission.account) if with_file_links

      timezone = account.timezone
      timezone = last_submitter.timezone || account.timezone if with_submitter_timezone

      lockup = load_lockup(composer.document)

      composer.page_style(:first, page_size:, next_style: :default) do |canvas, style|
        draw_band(canvas, composer.document, lockup)

        style.frame = style.create_frame(canvas.context, [BAND_HEIGHT + CORAL_RULE_HEIGHT + 26, MARGIN_X,
                                                          FOOTER_HEIGHT + 14, MARGIN_X])
      end

      running_header = [Stevensed::PRODUCT_NAME, t(:running_header, id: submission.id)]

      composer.page_style(:default, page_size:) do |canvas, style|
        draw_running_header(canvas, composer.document, running_header)

        style.frame = style.create_frame(canvas.context, [MARGIN_X, MARGIN_X, FOOTER_HEIGHT + 14, MARGIN_X])
      end

      composer.style(:base, font: SANS, font_size: FONT_SIZE, fill_color: INK, line_spacing: 1.35)
      composer.style(:link, fill_color: NAVY, underline: true)
      composer.style(:label, font: [SANS, { variant: :bold }], fill_color: MUTED)
      composer.style(:eyebrow, font: [SANS, { variant: :bold }], font_size: TYPE[:label], fill_color: MUTED,
                               character_spacing: 0.7)
      composer.style(:hash, font: MONO, font_size: MONO_SIZE, fill_color: INK, line_spacing: 1.45,
                            padding: [MONO_BASELINE_SHIFT, 0, 0, 0])
      composer.style(:section, font: [SERIF, { variant: :bold }], font_size: TYPE[:section], fill_color: INK,
                               padding: [gap.call(18), 0, 4, 0])

      composer.new_page(:first)

      completed_at = last_submitter&.completed_at

      composer.text(account.testing? ? I18n.t('testing_log_not_for_production_use') : t(:title),
                    font: [SERIF, { variant: :bold }], font_size: TYPE[:title], fill_color: INK,
                    padding: [0, 0, gap.call(8), 0])

      layout = composer.document.layout
      # An empty cell has no height and HexaPDF can never place it, so empty values read "Not recorded".
      cell = ->(value, **options) { layout.text_box(value.to_s.presence || t(:not_recorded), **options) }
      strong = ->(value) { layout.text_box(value.to_s, font: [SANS, { variant: :bold }]) }

      zone = ActiveSupport::TimeZone[timezone.to_s] || ActiveSupport::TimeZone['UTC']
      sender = submission.created_by_user if with_audit_sender
      signer_count = submission.submitters.size

      summary_rows = [
        [I18n.t('envelope_id'), cell.call(submission.id)],
        [t(:document), cell.call(TextUtils.maybe_rtl_reverse((submission.name || submission.template&.name).to_s))],
        [t(:status), cell.call(t(:status_completed, count: signer_count, total: signer_count))],
        sender && [t(:sender), cell.call(sender_label(sender))],
        [t(:created), cell.call(format_time(submission.created_at, timezone, :long))],
        completed_at && [t(:completed), cell.call(format_time(completed_at, timezone, :long))],
        [t(:signers), cell.call(signers_summary(submission, timezone))],
        [t(:issued_by), cell.call("#{Stevensed::LEGAL_ENTITY}, #{Stevensed::OFFICE}")],
        [t(:log_generated), cell.call(format_time(Time.current, timezone, :long))]
      ].compact

      if show_verify?(submission)
        summary_rows << [I18n.t('verify'),
                         layout.formatted_text_box(["#{t(:verify_note)} ",
                                                    { link: Stevensed::PKI_URL, style: :link,
                                                      text: Stevensed::PKI_URL.delete_suffix('/') }, '.'])]
      end

      draw_table(composer, summary_rows.map { |label, value| [cell.call(label), value] },
                 header: [t(:envelope_heading, id: submission.id), ''], lead: heading_boxes(composer, t(:summary)),
                 padding: cell_padding)
      offset = zone.at(completed_at || Time.current).formatted_offset
      composer.text(t(:times_note, zone: zone.tzinfo.name, offset:),
                    font_size: TYPE[:meta], fill_color: MUTED, padding: [5, 0, gap.call(4), 0])

      single_document = submission.schema_documents.size <= 1
      result_documents = select_attachments(last_submitter)
      # Each document after the first opens with its own header row, so that its rows stay together.
      documents_rows = result_documents.each_with_index.flat_map do |document, document_index|
        original_documents = submission.schema_documents.select do |e|
          e.uuid == (document.metadata['original_uuid'] || document.uuid)
        end.presence

        original_documents ||= submission.template.documents.select do |e|
          e.image? && (submission.template_schema.presence || submission.template.schema).any? do |item|
            item['attachment_uuid'] == e.uuid
          end
        end

        original_hashes = original_documents.map { |attachment| sha256_hex(attachment) }

        [
          (if document_index.positive?
             { header: [t(:document_count, number: document_index + 1, total: result_documents.size), ''] }
           end),
          [cell.call(t(:file_name)), strong.call(TextUtils.maybe_rtl_reverse(document.filename.to_s))],
          original_hashes.present? &&
            [cell.call(t(:original_sha256)),
             cell.call(original_hashes.first(CHECKSUM_LIMIT).join("\n\n"), style: :hash)],
          [cell.call(t(:result_sha256)), cell.call(sha256_hex(document), style: :hash)],
          (pages = page_count(document)) && [cell.call(t(:pages)), cell.call(pages)],
          [cell.call(t(:sealed)), cell.call(format_time(document.created_at, timezone, :long))]
        ].select(&:itself)
      end

      if documents_rows.present?
        draw_table(composer, documents_rows,
                   header: [t(:document_count, number: 1, total: result_documents.size), ''],
                   continued: t(:continued, heading: t(:documents)),
                   lead: heading_boxes(composer, t(:documents)), margin: gap.call(4),
                   padding: cell_padding)
      end

      signers_heading = false

      submission.template_submitters.each_with_index.filter_map do |item, position|
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

        signer_name = Stevensed::SignerName.for(submitter)

        identity_rows = [
          signer_name && [t(:name), strong.call(TextUtils.maybe_rtl_reverse(signer_name.squish))],
          # A zero-width space after the @ lets a long address wrap there rather than mid-word.
          submitter.email && [t(:email), cell.call(submitter.email.squish.sub('@', "@\u200B"))],
          submitter.phone && [t(:phone), cell.call(submitter.phone.squish)],
          submitter.completed_at && [t(:signed), cell.call(format_time(submitter.completed_at, timezone, :long))]
        ].compact

        # The consent record is one or more "Label: value" lines; each becomes a row like the other details.
        consent_rows =
          if esign_consent_event
            stamp = ->(time) { format_time(time, timezone, :long) }
            lines = Stevensed::Consents.audit_line(esign_consent_event, timezone:, stamp:).lines.map(&:strip)
                                       .compact_blank
            lines.map { |line| line.split(': ', 2) }.map { |label, value| [label, value.to_s.upcase_first] }
          end

        detail_rows = [
          *(submitter.viewer? && detail.call(t(:access), I18n.t('view_only'))),
          *(submitter.email && (click_email_event || verify_email_event) &&
            detail.call(t(:authentication), verify_email_event ? t(:auth_email_code) : t(:auth_email_link))),
          *(submitter.phone && verify_phone_event && detail.call(I18n.t('phone_verification'), I18n.t('verified'))),
          *(is_id_verified && detail.call(I18n.t('identity_verification'), I18n.t('verified'))),
          *(complete_kba_event.persisted? &&
            detail.call(I18n.t('knowledge_based_authentication'), "#{I18n.t('passed')}#{kba_score}")),
          *consent_rows,
          *((record = consent_record(submitter)) && detail.call(t(:consent_record), record)),
          *(completed_event.data['ip'] && detail.call(t(:ip_address), [completed_event.data['ip'], :hash])),
          *(completed_event.data['sid'] && detail.call(I18n.t('session_id'), [completed_event.data['sid'], :hash])),
          *(completed_event.data['ua'] && detail.call(t(:browser), browser_summary(completed_event.data['ua']))),
          *(completed_event.data['ua'] && detail.call(t(:user_agent), completed_event.data['ua'].to_s.squish)),
          *(submitter.timezone && detail.call(t(:time_zone), submitter.timezone.to_s.sub('Kiev', 'Kyiv')))
        ].grep(Array)

        signer_rows = identity_rows.map { |label, value| [cell.call(label), value] } +
                      detail_rows.map do |label, (value, style)|
                        [cell.call(label), style ? cell.call(value, style:) : cell.call(value)]
                      end

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
          page = field.dig('areas', 0, 'page')
          label = "#{label} (#{t(:page, number: page + 1)})" if page && single_document

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

              if field['type'].in?(%w[signature initials])
                method = attachment.metadata.to_h['signature_method']
                caption = t(:"signature_method_#{method.presence_in(%w[typed drawn upload]) || 'unknown'}")

                [image_box, layout.text_box(caption, font_size: TYPE[:meta], fill_color: MUTED),
                 (if with_signature_id
                    layout.text_box("ID #{attachment.uuid.upcase}", style: :hash, fill_color: MUTED)
                  end)]
                  .compact
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

        # One table per signer: who signed and how, then what they entered under a second header row. Long
        # tables continue on the next page under a repeated header row.
        lead = signers_heading ? [] : heading_boxes(composer, t(:signers))
        moved_lead = heading_boxes(composer, t(:continued, heading: t(:signers)))
        signers_heading = true
        rows = signer_rows
        rows += [{ header: [t(:submitted_entries), ''] }, *field_rows] if field_rows.present?
        signer_heading = t(:signer_heading, number: position + 1, total: submission.template_submitters.size,
                                            role: TextUtils.maybe_rtl_reverse(item['name'].to_s))

        draw_table(composer, rows, header: [signer_heading, ''], lead:, moved_lead:, keep: true,
                                   continued: t(:continued, heading: t(:signer_short, number: position + 1)),
                                   margin: gap.call(18), padding: cell_padding)
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
          if (stevensed_text = Stevensed::Records.event_text(event, submitter_name))
            stevensed_text
          elsif event.event_type == 'complete_verification'
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
            [
              I18n.t("submission_event_names.#{event.event_type}_to_html", submitter_name:),
              "<b>#{I18n.t(:from)}</b> #{TextUtils.maybe_rtl_reverse(sender_label(submission.created_by_user))}"
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

        if event.event_type.in?(%w[send_email send_reminder_email]) && submitter.email.present?
          text_box = [*text_box, " (#{submitter.email.squish.sub('@', "@\u200B")})"]
        end

        ip =
          if event.event_type.start_with?('send_') then t(:sent_by_system)
          elsif event.data['ip'].present? then "IP #{event.data['ip']}"
          else t(:ip_not_recorded)
          end
        text_box = [*text_box, "\n", { text: ip, font: event.data['ip'].present? ? MONO : SANS,
                                       font_size: event.data['ip'].present? ? MONO_SIZE : TYPE[:meta],
                                       fill_color: MUTED }]
        [event.event_timestamp, composer.document.layout.formatted_text_box(text_box)]
      end

      bold = [SANS, { variant: :bold }]
      system_line = { text: "\n#{t(:system_event)}", font_size: TYPE[:meta], fill_color: MUTED }
      created_text =
        if sender
          [{ text: t(:event_created), font: bold }, " #{t(:by)} #{sender_label(sender)}",
           { text: "\n#{t(:ip_not_recorded)}", font_size: TYPE[:meta], fill_color: MUTED }]
        else
          [{ text: t(:event_created), font: bold }, system_line]
        end
      events_data.unshift([submission.created_at, layout.formatted_text_box(created_text)])

      if completed_at
        events_data << [completed_at, layout.formatted_text_box([{ text: t(:event_completed), font: bold },
                                                                 " #{t(:event_completed_detail)}", system_line])]
      end

      if (sealed_at = select_attachments(last_submitter).map(&:created_at).max)
        events_data << [sealed_at, layout.formatted_text_box([{ text: t(:event_sealed), font: bold },
                                                              " #{t(:event_sealed_detail)}", system_line])]
      end

      # One row per event under a row for each day, so that times line up in a single column.
      clock = lambda do |time|
        "#{Stevensed.format_datetime(time, timezone, seconds: true).split(', ', 2).last}\n#{utc_time(time)}"
      end
      days = events_data.sort_by(&:first).chunk { |time, _| time.in_time_zone(timezone).to_date }
      event_rows = days.flat_map do |date, events|
        [{ group: strong.call(Stevensed.format_date(date)) },
         *events.map { |time, box| [cell.call(clock.call(time)), box] }]
      end

      if event_rows.present?
        draw_table(composer, event_rows, header: [t(:time), t(:event)], label_column: false, keep: true,
                                         column_widths: [EVENT_TIME_WIDTH, -1],
                                         lead: [*heading_boxes(composer, I18n.t('event_log')),
                                                layout.text_box(t(:event_times_note, zone: zone.tzinfo.name, offset:),
                                                                font_size: TYPE[:meta], fill_color: MUTED,
                                                                margin: [0, 0, 6, 0])],
                                         margin: gap.call(18),
                                         padding: cell_padding)
      end

      add_certificate_summary(composer, account, timezone, padding: cell_padding, sealed_at:)

      frame = composer.frame
      fill = 1 - (frame.available_height / frame.height)

      add_footers(composer.document, submission, with_signature_id)

      [composer.document, fill]
    end

    # A section heading and its hairline, kept with whatever is drawn after them.
    def heading_boxes(composer, title)
      [composer.document.layout.text_box(title, style: :section, margin: [0, 0, 6, 0])]
    end

    # Draws a table page by page instead of letting it split anywhere. Rows never split; the navy header row
    # repeats on every page; a page never opens or closes with fewer than MIN_ROWS rows (a shorter table moves
    # whole); and the lead boxes (section heading, signer card) stay with the first rows.
    def draw_table(composer, rows, header:, lead: [], column_widths: [LABEL_COLUMN_WIDTH, -1], label_column: true,
                   keep: false, moved_lead: nil, continued: nil, margin: 0, padding: CELL_PADDING)
      layout = composer.document.layout
      header_cells = lambda do |texts|
        # A table without column names is capped by a thin navy rule instead of an empty bar.
        next texts.map { rule_cell } if texts.all?(&:blank?)

        texts.map do |value|
          { content: layout.text_box(value.to_s.upcase, style: :eyebrow, fill_color: 'FFFFFF'), background_color: NAVY,
            padding: }
        end
      end
      continued = [continued || t(:continued, heading: header.first), *header.drop(1)]
      # HexaPDF takes cell hashes apart when it builds a table, so every table gets fresh ones. A row given as
      # { header: [...] } is a header row inside the table, set apart by a gap; { group: box } is a row spanning the
      # table (the day in the event log). Otherwise the first column is the label column.
      table = lambda do |indexes, with_header: true, bottom: 0, first: true|
        part = indexes.map do |index|
          row = rows[index]
          next header_cells.call(row[:header]) if row.is_a?(Hash) && row[:header]
          next [{ content: row[:group], col_span: column_widths.size, background_color: LABEL_CELL }] if row.is_a?(Hash)

          label_column ? [{ content: row.first, background_color: LABEL_CELL }, *row.drop(1)] : row
        end

        layout.table_box(part, column_widths: column_widths.dup,
                               header: (->(_t) { [header_cells.call(first ? header : continued)] } if with_header),
                               cell_style: { padding:, border: { width: [0, 0, HAIRLINE, 0], color: RULE } },
                               margin: [0, 0, bottom, 0])
      end

      heights = rows.each_index.map { |index| measure(composer, table.call([index], with_header: false)) }
      header_height = measure(composer, table.call([0])) - heights.first
      lead_height = lead.sum { |box| measure(composer, box) }

      index = 0
      total_height = header_height + heights.sum + lead_height

      # A table kept whole moves to the next page when it fits there and less than half of this page is left
      # (under a "continued" section heading); otherwise it continues under a repeated header row.
      if keep && total_height > composer.frame.available_height && total_height <= composer.frame.height &&
         composer.frame.available_height < composer.frame.height / 2
        composer.new_page
        lead = moved_lead if moved_lead && lead.empty?
        lead_height = lead.sum { |box| measure(composer, box) }
      end

      day_row = ->(row) { row.is_a?(Hash) && row[:group] }

      while index < rows.size
        # On a continuation page, the day row the rows belong to is repeated above them.
        group = rows[...index].rindex(&day_row) unless index.zero? || rows[index].is_a?(Hash)
        room = composer.frame.available_height - header_height - (index.zero? ? lead_height : 0) -
               (group ? heights[group] : 0)
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
          # A header row inside the table keeps at least MIN_ROWS of its rows (or all of them) on its page.
          if (inner = (index...(index + fit)).to_a.rfind { |i| rows[i].is_a?(Hash) })
            inner_rows = rows[(inner + 1)..].take_while { |row| !row.is_a?(Hash) }.size
            fit = inner - index if index + fit - inner - 1 < [MIN_ROWS, inner_rows].min
          end
          fresh = composer.frame.available_height >= composer.frame.height - 1

          if fit < [MIN_ROWS, remaining].min && !fresh
            composer.new_page
            next
          end

          fit = fit.clamp(1, remaining)
        end

        # Continuation pages repeat the header row, marked as continued. The part is measured as it will be
        # drawn, so that HexaPDF never has to split it.
        part = lambda do |count|
          table.call([*group, *(index...(index + count))], first: index.zero?,
                                                           bottom: index + count == rows.size ? margin : 0)
        end
        space = composer.frame.available_height - (index.zero? ? lead_height : 0)
        fit -= 1 while fit > 1 && measure(composer, part.call(fit)) > space

        lead.each { |box| composer.draw_box(box) } if index.zero?
        composer.draw_box(part.call(fit))
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

    CURVE_NAMES = { 'secp384r1' => 'P-384', 'prime256v1' => 'P-256', 'secp521r1' => 'P-521' }.freeze

    # StevensED: the issuing CA's signature over the certificate, kept apart from the certificate's own key, e.g.
    # "StevensED Document Signing CA (ECDSA P-384, SHA-384)" next to "Key: RSA 3072-bit".
    def certificate_signature_text(certificate, chain, name_part)
      issuer_cert = chain.find { |c| c.subject.to_der == certificate.issuer.to_der }
      issuer_name = name_part.call(certificate.issuer, 'CN') || certificate.issuer.to_s
      algorithm = certificate.signature_algorithm.to_s
      digest = algorithm[/sha-?(\d{3})/i, 1]&.then { |bits| "SHA-#{bits}" }
      family =
        if algorithm.match?(/ecdsa/i)
          curve = issuer_cert&.public_key.is_a?(OpenSSL::PKey::EC) ? issuer_cert.public_key.group.curve_name : nil
          ['ECDSA', CURVE_NAMES[curve]].compact.join(' ')
        elsif algorithm.match?(/rsa/i)
          'RSA'
        end
      details = [family, digest].compact.join(', ')

      details.present? ? "#{issuer_name} (#{details})" : "#{issuer_name} (#{algorithm})"
    end

    def add_certificate_summary(composer, account, timezone, padding: CELL_PADDING, sealed_at: nil)
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

      dn = lambda do |name|
        %w[CN O OU C].filter_map { |part| (value = name_part.call(name, part)) && "#{part}=#{value}" }.join(', ')
      end
      key = certificate.public_key
      key_text = key.is_a?(OpenSSL::PKey::RSA) ? "RSA #{key.n.num_bits}-bit" : key.oid

      rows = [
        [t(:signed_by), dn.call(certificate.subject)],
        [t(:certificate_issuer), dn.call(certificate.issuer)],
        root && [t(:root_certificate), dn.call(root.subject)],
        [t(:serial_number), hex_bytes(certificate.serial.to_s(16)), :hash],
        [t(:valid), "#{Stevensed.format_date(certificate.not_before.in_time_zone(timezone))} to " \
                    "#{Stevensed.format_date(certificate.not_after.in_time_zone(timezone))}"],
        sealed_at && [t(:valid_at_sealing),
                      sealed_at.between?(certificate.not_before, certificate.not_after) ? t(:valid_yes) : t(:valid_no)],
        [t(:sha256_fingerprint), hex_bytes(OpenSSL::Digest::SHA256.hexdigest(certificate.to_der)), :hash],
        [t(:public_key), key_text],
        [t(:certificate_signed_by), certificate_signature_text(certificate, chain, name_part)],
        [t(:revocation), t(:revocation_note)],
        [t(:time_stamp_authority), tsa_host || t(:no_tsa)]
      ].compact

      layout = composer.document.layout
      verify = layout.formatted_text_box(["#{t(:verification)} ",
                                          { link: Stevensed::PKI_URL, text: Stevensed::PKI_URL.delete_suffix('/'),
                                            style: :link }, ". #{t(:verify_file)}"])

      table = layout.table_box(
        [
          *rows.map do |label, value, style|
            [layout.text_box(label.to_s), style ? layout.text_box(value.to_s, style:) : layout.text_box(value.to_s)]
          end,
          [layout.text_box(t(:how_to_verify)), verify],
          [layout.text_box(t(:record)), layout.text_box(t(:certification))]
        ],
        column_widths: [LABEL_COLUMN_WIDTH, -1],
        header: lambda do |_table|
          [[header_cell(layout, t(:certificate_heading), padding), header_cell(layout, '', padding)]]
        end,
        cell_style: lambda do |cell|
          cell.style.update(padding:, border: { width: [0, 0, HAIRLINE, 0], color: RULE })
          cell.style.update(background_color: LABEL_CELL) if cell.column.zero?
        end,
        margin: [0, 0, 4, 0]
      )

      boxes = [*heading_boxes(composer, t(:signing_certificate)), table]
      keep_together(composer, boxes)
      boxes.each { |box| composer.draw_box(box) }
    end

    def header_cell(layout, text, padding)
      { content: layout.text_box(text.to_s.upcase.presence || ' ', style: :eyebrow, fill_color: 'FFFFFF'),
        background_color: NAVY, padding: }
    end

    def rule_cell
      { content: HexaPDF::Layout::Box.create(height: 3), background_color: NAVY, padding: 0 }
    end

    # A file's SHA-256 in lowercase hexadecimal, as sha256sum prints it, in groups of eight characters on two lines.
    # Stored values are URL-safe Base64; a file without one is hashed here.
    def sha256_hex(attachment)
      stored = attachment.metadata.to_h['sha256']
      hex = Base64.urlsafe_decode64(stored).unpack1('H*') if stored.present?
      hex = Digest::SHA256.hexdigest(attachment.download) unless hex&.length == 64

      hex.scan(/.{8}/).each_slice(4).map { |groups| groups.join(' ') }.join("\n")
    rescue ArgumentError
      Digest::SHA256.hexdigest(attachment.download).scan(/.{8}/).each_slice(4).map { |g| g.join(' ') }.join("\n")
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

    # The product name on the left and the log and envelope on the right, above a hairline.
    def draw_running_header(canvas, document, (left_text, right_text))
      box = canvas.context.box(:media)
      rule_y = box.height - HEADER_RULE_FROM_TOP

      canvas.save_graphics_state do
        canvas.stroke_color(RULE).line_width(HAIRLINE).line(MARGIN_X, rule_y, box.width - MARGIN_X, rule_y).stroke
      end

      style = { font: SANS, font_size: TYPE[:label], fill_color: MUTED }
      width = box.width - (MARGIN_X * 2)

      draw_text_box(canvas, document.layout.text_box(left_text, **style), MARGIN_X, rule_y + 5, width / 2, 14)
      draw_text_box(canvas, document.layout.text_box(right_text, **style, text_align: :right),
                    MARGIN_X + (width / 2), rule_y + 5, width / 2, 14)
    end

    def add_footers(document, submission, with_signature_id)
      pages = document.pages.to_a

      left_text =
        if submission.account.testing?
          TESTING_FOOTER
        else
          "#{Stevensed::LEGAL_ENTITY}, #{Stevensed::OFFICE}, #{Docuseal.default_url_options[:host]}"
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

        page_label = t(:footer_page, id: submission.id, number: index + 1, total: pages.size)

        footer_style = { font: SANS, font_size: TYPE[:label], fill_color: MUTED }

        draw_text_box(canvas, document.layout.text_box(left_text, **footer_style),
                      MARGIN_X, 18, width * 0.72, FOOTER_HEIGHT - 24)
        draw_text_box(canvas, document.layout.text_box(page_label, **footer_style,
                                                                                      text_align: :right),
                      MARGIN_X + (width * 0.72), 18, width * 0.28, FOOTER_HEIGHT - 24)
      end
    end

    def t(key, **)
      I18n.t(key, scope: 'stevensed.audit_log', **)
    end

    # Every time in the log carries seconds and its zone abbreviation, with the same moment in UTC (ISO 8601).
    def format_time(time, timezone, _format)
      "#{Stevensed.format_datetime(time, timezone, seconds: true)} (#{utc_time(time)})"
    end

    # Who signed and when, for the summary: "Jordan Reyes (Instructor), signed 1:11:50 PM MST".
    def signers_summary(submission, timezone)
      submission.template_submitters.filter_map do |item|
        submitter = submission.submitters.find { |e| e.uuid == item['uuid'] }
        next unless submitter&.completed_at

        name = Stevensed::SignerName.for(submitter) || submitter.email
        time = format_time(submitter.completed_at, timezone, :long)

        t(:signer_summary, name: TextUtils.maybe_rtl_reverse(name.to_s.squish),
                           role: TextUtils.maybe_rtl_reverse(item['name'].to_s), time:)
      end.join("\n\n")
    end

    # Non-breaking hyphens and spaces keep a UTC time on one line.
    def utc_time(time)
      time.utc.strftime('%Y-%m-%d %H:%M:%S UTC').tr('-', "\u2011").tr(' ', "\u00A0")
    end

    # The sender's name, with their address only when it is an institutional (stevensed.org) one.
    def sender_label(user)
      name = user.full_name.to_s.squish.presence || t(:staff_member)
      email = user.email.to_s

      email.end_with?('@stevensed.org') ? "#{name} (#{email})" : name
    end

    # The result PDF's page count, or nil when it cannot be read.
    def page_count(attachment)
      HexaPDF::Document.new(io: StringIO.new(attachment.download)).pages.count
    rescue StandardError
      nil
    end

    # The consent form and version on record for the signer, such as "FRM-102-A version 3.1".
    def consent_record(submitter)
      key, version = StevensedEsignConsent.where(submitter_id: submitter.id).order(:id).pick(:form_key, :form_version)

      [key, (t(:version, number: version) if version.present?)].compact.join(' ').presence
    end

    BROWSERS = [['Edge', %r{Edg/([\d.]+)}], ['Firefox', %r{Firefox/([\d.]+)}], ['Chrome', %r{Chrome/([\d.]+)}],
                ['Safari', %r{Version/([\d.]+).*Safari/}]].freeze
    SYSTEMS = [['iPhone', /iPhone OS ([\d_]+)/], ['iPad', /iPad.*OS ([\d_]+)/], ['Android', /Android ([\d.]+)/],
               ['macOS', /Mac OS X ([\d_]+)/], ['Windows', /Windows NT ([\d.]+)/], ['Linux', /Linux/]].freeze

    # A readable summary of a user agent string, such as "Safari 19.1 on macOS 10.15.7".
    def browser_summary(user_agent)
      ua = user_agent.to_s
      browser = BROWSERS.lazy.filter_map do |name, re|
        (m = ua.match(re)) && "#{name} #{m[1].split('.').first(2).join('.')}"
      end.first
      system = SYSTEMS.lazy.filter_map do |name, re|
        (m = ua.match(re)) && [name, m[1]&.tr('_', '.')].compact.join(' ')
      end.first

      [browser || t(:unknown_browser), system].compact.join(" #{t(:on)} ")
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
