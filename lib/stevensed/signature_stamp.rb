# frozen_string_literal: true

module Stevensed
  # Signature ID marks on signed documents ("Add signature ID to the documents"), set to match the audit log:
  # Inter in StevensED navy, a coral rule beside each signature stamp, and a quiet per-page line in the bottom
  # margin below the form's own footer. Text in scripts Inter does not cover is set in the result PDF's
  # default font (Go Noto Kurrent in production) so that names never drop out.
  module SignatureStamp
    INK = '1F2948'
    MUTED = '5B6478'
    CORAL = 'C13F44'

    FONTS_DIR = Rails.root.join('lib/stevensed/fonts')
    REGULAR_PATH = FONTS_DIR.join('Inter-Regular.ttf').to_s
    BOLD_PATH = FONTS_DIR.join('Inter-SemiBold.ttf').to_s

    MAX_FONT_SIZE = 7
    MIN_FONT_SIZE = 3.5
    LINE_SPACING = 1.12
    RULE_GAP = 3

    # Distance of the per-page line's baseline from the bottom edge. StevensED forms keep their own footer
    # between 30 and 37 pt from the bottom, so the line sits clear of it.
    FOOTER_BASELINE = 14
    FOOTER_FONT_SIZE = 6

    module_function

    def font(pdf, text, bold: false, fallback: nil)
      font = pdf.fonts.add(bold ? BOLD_PATH : REGULAR_PATH)

      return font if covers?(font, text) || fallback.nil?

      pdf.fonts.add(fallback)
    end

    def covers?(font, text)
      cmap = font.wrapped_font[:cmap].preferred_table

      text.to_s.each_codepoint.all? { |codepoint| codepoint < 32 || cmap[codepoint] }
    end

    # Draws the stamp text in the box whose top-left corner is (left, top). lines[0] is the signer line, the
    # remaining lines are the time and any reason, and the signature ID goes last. The text is made smaller until
    # it fits; lines that still do not fit at the minimum size are left out rather than drawn over the page.
    # Returns the font size used.
    def draw(canvas, pdf, left:, top:, width:, height:, id:, lines:, fallback: nil)
      text_left = left + RULE_GAP + 0.6
      text_width = width - RULE_GAP - 0.6
      full_id = "ID #{id}".upcase
      font_size = [MAX_FONT_SIZE, height / ((lines.size + 1) * LINE_SPACING)].min

      result = nil
      layouter = HexaPDF::Layout::TextLayouter.new(line_spacing: { type: :proportional, value: LINE_SPACING })

      loop do
        id_text = fit_id(pdf, full_id, font_size * 0.92, text_width, fallback)
        result = layouter.fit(fragments(pdf, lines, id_text, font_size, fallback), text_width, height)

        break if result.status == :success || font_size < MIN_FONT_SIZE

        font_size *= 0.92
      end

      used_height = result.lines.sum(&:height) * LINE_SPACING
      text_top = top - [(height - used_height) / 2.0, 0].max

      canvas.save_graphics_state do
        canvas.stroke_color(CORAL).line_width(0.6)
              .line(left + 0.3, text_top, left + 0.3, text_top - [used_height, height].min).stroke
      end

      result.draw(canvas, text_left, text_top)

      font_size
    end

    # Shortens the ID only when it is wider than the stamp; the full ID is always in the audit log.
    def fit_id(pdf, id_text, font_size, width, fallback)
      id_text = "#{id_text.delete_suffix('...')[0..-2]}..." while id_text.length > 14 &&
                                                                  fragment(pdf, id_text, font_size, MUTED,
                                                                           fallback:).width > width
      id_text
    end

    def fragments(pdf, lines, id_text, font_size, fallback)
      signer, *rest = lines

      items = [fragment(pdf, signer, font_size, INK, bold: true, fallback:)]
      rest.each { |line| items.push(newline(pdf, font_size), fragment(pdf, line, font_size, MUTED, fallback:)) }
      items.push(newline(pdf, font_size), fragment(pdf, id_text, font_size * 0.92, MUTED, fallback:))

      items
    end

    def fragment(pdf, text, font_size, color, bold: false, fallback: nil)
      HexaPDF::Layout::TextFragment.create(text.to_s, font: font(pdf, text, bold:, fallback:), font_size:,
                                                      fill_color: color)
    end

    def newline(pdf, font_size)
      HexaPDF::Layout::TextFragment.create("\n", font: pdf.fonts.add(REGULAR_PATH), font_size:)
    end

    # The per-page line: centred in the bottom margin, on a tight white underlay so that it stays legible on
    # documents that print to the edge.
    def draw_footer(page, pdf, text, fallback: nil)
      canvas = page.canvas(type: :overlay)
      box = page.box
      font_size = [FOOTER_FONT_SIZE * ([box.width, box.height].min / 612.0), 4].max
      fragment = fragment(pdf, text, font_size, MUTED, fallback:)

      text_width = fragment.width
      left = box.left + ((box.width - text_width) / 2.0)
      baseline = box.bottom + (FOOTER_BASELINE * (font_size / FOOTER_FONT_SIZE))

      canvas.save_graphics_state do
        canvas.fill_color('FFFFFF')
              .rectangle(left - 3, baseline - (font_size * 0.35), text_width + 6, font_size * 1.3).fill
      end

      HexaPDF::Layout::TextLayouter.new.fit([fragment], text_width + 1, font_size * 2)
                                   .draw(canvas, left, baseline + (font_size * 0.95))
    end

    def footer_text(document_id, testing: false)
      text = "#{Stevensed::PRODUCT_NAME} · #{I18n.t('document_id')} #{document_id}"

      testing ? "#{Submissions::GenerateResultAttachments::TESTING_FOOTER} · #{text}" : text
    end
  end
end
