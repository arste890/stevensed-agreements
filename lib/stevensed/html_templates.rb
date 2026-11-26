# frozen_string_literal: true

module Stevensed
  # StevensED: creates a template from HTML.
  #
  # The HTML is sanitized, converted to PDF with Gotenberg (Chromium) and its field tags become template fields:
  #
  #   <text-field name="Full name" role="Parent" required="true" style="width: 200px; height: 20px"></text-field>
  #   <signature-field>, <initials-field>, <date-field>, <checkbox-field>
  #
  # Each tag is replaced with an inline placeholder box. The document is converted twice with an identical
  # layout: the first conversion carries a short marker at the top left and bottom right corners of every box,
  # and the positions of those markers in the PDF (read with PDFium) give the field areas. The second
  # conversion, without markers, becomes the template document.
  module HtmlTemplates
    Error = Class.new(StandardError)

    FIELD_TYPES = {
      'text-field' => 'text',
      'signature-field' => 'signature',
      'initials-field' => 'initials',
      'date-field' => 'date',
      'checkbox-field' => 'checkbox'
    }.freeze

    # Default box sizes in CSS pixels.
    DEFAULT_SIZES = {
      'text' => [200, 24],
      'signature' => [220, 60],
      'initials' => [80, 40],
      'date' => [120, 24],
      'checkbox' => [18, 18]
    }.freeze

    # Paper sizes in inches (width, height).
    PAPER_SIZES = {
      'letter' => [8.5, 11],
      'legal' => [8.5, 14],
      'a4' => [8.27, 11.69],
      'a5' => [5.83, 8.27]
    }.freeze

    MAX_HTML_SIZE = 2.megabytes
    MAX_FIELDS = 300
    MAX_NAME_LENGTH = 255
    MARKER_REGEXP = /QZ(\d+)([SE])Z/
    MARKER_STYLE = 'position:absolute;font:5px/5px monospace;color:#000;white-space:nowrap;letter-spacing:0;'

    Field = Struct.new(:index, :type, :name, :role, :required, :width, :height, :style, keyword_init: true)

    module_function

    # Returns the saved template. Raises Stevensed::HtmlTemplates::Error with a message that is safe to show.
    def call(account:, author:, html:, html_header: nil, html_footer: nil, name: nil, size: nil,
             folder_name: nil, external_id: nil, source: 'native')
      validate_input!(html, html_header, html_footer)

      document = HtmlSanitizer.call(html)
      fields = extract_fields(document)
      tagged_html = document.to_html

      options = conversion_options(size, html_header, html_footer)

      marked_pdf = Stevensed::Gotenberg.html_to_pdf(render(tagged_html, fields, markers: true), **options)
      final_pdf = Stevensed::Gotenberg.html_to_pdf(render(tagged_html, fields, markers: false), **options)

      areas = locate_fields(marked_pdf, fields)

      create_template(account:, author:, name: template_name(name, document), folder_name:, external_id:,
                      source:, pdf: final_pdf, fields:, areas:)
    rescue Stevensed::Gotenberg::Error, Pdfium::PdfiumError, SystemCallError, SocketError, Timeout::Error, KeyError => e
      Rails.logger.error("HTML template conversion failed: #{e.class}: #{e.message}")

      raise Error, 'The HTML could not be converted to PDF.'
    end

    def validate_input!(html, html_header, html_footer)
      raise Error, 'html is required.' if html.blank? || !html.is_a?(String)

      [html, html_header, html_footer].each do |value|
        next if value.nil?

        raise Error, 'html, html_header and html_footer must be strings.' unless value.is_a?(String)
        raise Error, 'The HTML is larger than 2 MB.' if value.bytesize > MAX_HTML_SIZE
      end
    end

    def extract_fields(document)
      nodes = document.css(FIELD_TYPES.keys.join(','))

      raise Error, "The HTML has more than #{MAX_FIELDS} field tags." if nodes.size > MAX_FIELDS

      nodes.each_with_index.map do |node, index|
        type = FIELD_TYPES.fetch(node.name)
        style = node['style'].to_s
        default_width, default_height = DEFAULT_SIZES.fetch(type)

        field = Field.new(
          index:,
          type:,
          name: node['name'].to_s.strip.first(MAX_NAME_LENGTH).presence,
          role: node['role'].to_s.strip.first(MAX_NAME_LENGTH).presence,
          required: node['required'].nil? ? type != 'checkbox' : node['required'].to_s.strip.downcase != 'false',
          width: css_dimension(style, 'width') || "#{default_width}px",
          height: css_dimension(style, 'height') || "#{default_height}px",
          style:
        )

        node['data-stevensed-field'] = index.to_s

        field
      end
    end

    def css_dimension(style, property)
      style[/(?:\A|;)\s*#{property}\s*:\s*([0-9.]+(?:px|pt|mm|cm|in|em|rem|%))\s*(?:;|\z)/i, 1]
    end

    def render(tagged_html, fields, markers:)
      doc = Nokogiri::HTML5.parse(tagged_html)

      fields.each do |field|
        node = doc.at_css("[data-stevensed-field='#{field.index}']")

        placeholder = doc.create_element('span')
        placeholder['style'] = placeholder_style(field)
        placeholder['class'] = "stevensed-field stevensed-field-#{field.type}"

        if markers
          placeholder.add_child(marker(doc, "QZ#{field.index}SZ", 'left:0;top:0;'))
          placeholder.add_child(marker(doc, "QZ#{field.index}EZ", 'right:0;bottom:0;'))
        end

        node.replace(placeholder)
      end

      doc.to_html
    end

    def placeholder_style(field)
      border =
        if field.type == 'checkbox'
          'border:1px solid #6b7280;'
        else
          'border-bottom:1px solid #6b7280;'
        end

      # Position, size and overflow come last so that the markers stay at the corners of the box.
      "display:inline-block;vertical-align:bottom;box-sizing:border-box;#{border}" \
        "#{field.style.gsub(/[<>]/, '')};position:relative;overflow:visible;" \
        "width:#{field.width};height:#{field.height};"
    end

    def marker(doc, text, position)
      span = doc.create_element('span', text)
      span['style'] = "#{MARKER_STYLE}#{position}"

      span
    end

    def conversion_options(size, html_header, html_footer)
      width, height = PAPER_SIZES.fetch(size.to_s.strip.downcase.presence || 'letter') do
        raise Error, "size must be one of: #{PAPER_SIZES.keys.map(&:capitalize).join(', ')}."
      end

      {
        paper_width: width,
        paper_height: height,
        header: html_header.present? ? HtmlSanitizer.call(html_header).to_html : nil,
        footer: html_footer.present? ? HtmlSanitizer.call(html_footer).to_html : nil
      }
    end

    # Returns { field_index => { 'page' => n, 'x' => .., 'y' => .., 'w' => .., 'h' => .. } }.
    def locate_fields(pdf, fields)
      markers = find_markers(pdf)

      fields.to_h do |field|
        start_marker = markers[[field.index, 'S']]
        end_marker = markers[[field.index, 'E']]

        unless start_marker && end_marker && start_marker[:page] == end_marker[:page]
          raise Error, "The position of field #{field.index + 1} could not be found. " \
                       'Keep each field tag on one page and avoid hiding it with CSS.'
        end

        [field.index, area_from_markers(start_marker, end_marker)]
      end
    end

    def area_from_markers(start_marker, end_marker)
      left, top = start_marker.values_at(:left, :top)
      right, bottom = end_marker.values_at(:right, :bottom)
      width, height = start_marker.values_at(:page_width, :page_height)

      right = left + 1 if right <= left
      bottom = top - 1 if bottom >= top

      {
        'page' => start_marker[:page],
        'x' => (left / width).clamp(0.0, 1.0),
        'y' => ((height - top) / height).clamp(0.0, 1.0),
        'w' => ((right - left) / width).clamp(0.0, 1.0),
        'h' => ((top - bottom) / height).clamp(0.0, 1.0)
      }
    end

    # Returns { [field_index, 'S' or 'E'] => { page:, left:, top:, right:, bottom:, page_width:, page_height: } }
    # in PDF points with the origin at the bottom left of the page.
    def find_markers(pdf)
      markers = {}

      Pdfium::Document.open_bytes(pdf) do |doc|
        doc.page_count.times do |page_index|
          page = doc.get_page(page_index)

          chars, boxes = page_chars(page)

          chars.join.to_enum(:scan, MARKER_REGEXP).each do
            match = Regexp.last_match
            rects = boxes[match.begin(0)...match.end(0)].compact

            next if rects.empty?

            markers[[match[1].to_i, match[2]]] ||= {
              page: page_index,
              left: rects.map { |r| r[0] }.min,
              top: rects.map { |r| r[1] }.max,
              right: rects.map { |r| r[2] }.max,
              bottom: rects.map { |r| r[3] }.min,
              page_width: page.width,
              page_height: page.height
            }
          end
        end
      end

      markers
    end

    # One entry per PDFium character index, so that string offsets map to character boxes.
    def page_chars(page)
      text_page = Pdfium.FPDFText_LoadPage(page.page_ptr)

      return [[], []] if text_page.null?

      count = Pdfium.FPDFText_CountChars(text_page)
      rect = FFI::MemoryPointer.new(:float, 4)

      chars = []
      boxes = []

      count.times do |index|
        codepoint = Pdfium.FPDFText_GetUnicode(text_page, index)

        chars << (codepoint.between?(0x20, 0x7E) ? codepoint.chr : ' ')

        if Pdfium.FPDFText_GetLooseCharBox(text_page, index, rect).zero?
          boxes << nil
        else
          left, top, right, bottom = rect.read_array_of_float(4)

          boxes << [left, top, right, bottom]
        end
      end

      [chars, boxes]
    ensure
      Pdfium.FPDFText_ClosePage(text_page) if text_page && !text_page.null?
    end

    def template_name(name, document)
      name.to_s.strip.presence || document.at_css('title')&.text.to_s.strip.presence || 'HTML template'
    end

    def create_template(account:, author:, name:, folder_name:, external_id:, source:, pdf:, fields:, areas:)
      template = Template.new(account:, author:, source:, name: name.first(MAX_NAME_LENGTH),
                              external_id: external_id.presence)
      template.folder = TemplateFolders.find_or_create_by_name(author, folder_name)

      template.submitters = build_submitters(fields)

      Templates.maybe_assign_access(template)

      template.save!

      file = ActionDispatch::Http::UploadedFile.new(
        tempfile: StringIO.new(pdf),
        filename: "#{template.name.parameterize.presence || 'document'}.pdf",
        type: Templates::CreateAttachments::PDF_CONTENT_TYPE
      )

      document = Templates::CreateAttachments.handle_pdf_or_image(template, file, pdf)

      template.update!(
        schema: [{ 'attachment_uuid' => document.uuid, 'name' => template.name }],
        fields: build_fields(fields, areas, template.submitters, document.uuid)
      )

      template
    rescue StandardError
      template.destroy if template&.persisted?

      raise
    end

    def build_submitters(fields)
      roles = fields.filter_map(&:role).uniq
      roles = [I18n.t('first_party')] if roles.empty?

      roles.map { |role| { 'name' => role, 'uuid' => SecureRandom.uuid } }
    end

    def build_fields(fields, areas, submitters, attachment_uuid)
      submitter_uuids = submitters.to_h { |s| [s['name'], s['uuid']] }
      counters = Hash.new(0)

      fields.map do |field|
        counters[field.type] += 1

        {
          'uuid' => SecureRandom.uuid,
          'submitter_uuid' => submitter_uuids.fetch(field.role, submitters.first['uuid']),
          'name' => field.name || "#{field.type.humanize} #{counters[field.type]}",
          'type' => field.type,
          'required' => field.required,
          'preferences' => {},
          'areas' => [areas.fetch(field.index).merge('attachment_uuid' => attachment_uuid)]
        }
      end
    end
  end
end
