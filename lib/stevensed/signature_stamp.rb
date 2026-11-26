# frozen_string_literal: true

module Stevensed
  # Signature ID marks on signed documents ("Add signature ID to the documents"), set to match the audit log:
  # Inter in StevensED navy, a coral rule beside each signature stamp, and a quiet per-page line in the bottom
  # margin below the form's own footer. Text in scripts Inter does not cover is set in the result PDF's
  # default font (Go Noto Kurrent in production) so that names never drop out.
  #
  # The stamp is set at 6 to 7 pt and never shares space with the signature: in a wide box the signature gets the
  # left part and the stamp the right; otherwise the stamp sits under the signature inside the box. Everything
  # stays inside the field's box.
  module SignatureStamp
    INK = '1F2948'
    MUTED = '5B6478'
    CORAL = 'C13F44'

    FONTS_DIR = Rails.root.join('lib/stevensed/fonts')
    REGULAR_PATH = FONTS_DIR.join('Inter-Regular.ttf').to_s
    BOLD_PATH = FONTS_DIR.join('Inter-SemiBold.ttf').to_s

    MAX_FONT_SIZE = 7
    MIN_FONT_SIZE = 6
    # Used only when a box is too small for 6 pt (for example a very short box drawn by hand in a template).
    SMALL_BOX_MIN_FONT_SIZE = 4.5
    FONT_SIZE_STEP = 0.25
    RULE_GAP = 3
    GAP = 6
    WIDE_RATIO = 3
    SIDE_SHARES = [0.5, 0.55, 0.6].freeze

    # Distance of the per-page line's baseline from the bottom edge. StevensED forms keep their own footer
    # between 30 and 37 pt from the bottom, so the line sits clear of it.
    FOOTER_BASELINE = 14
    FOOTER_FONT_SIZE = 6

    Plan = Struct.new(:mode, :result, :font_size, :width, :height, keyword_init: true)

    module_function

    # Draws the signature image and its stamp in the field box [left, top, width, height] (top-left corner).
    # signer: the signer's name; prefix and short_prefix: "Digitally signed by" and "Signed by" (or a reason);
    # time: the signing time. Returns the Plan used, or nil when only the signature could be drawn.
    def place(canvas, pdf, image:, box:, id:, signer:, prefix:, short_prefix:, time:, fallback: nil)
      left, top, width, height = box
      line_sets = ->(text_width) { line_sets(pdf, signer, prefix, short_prefix, time, text_width, fallback) }
      wide = height.positive? && (width / height) > WIDE_RATIO

      # In a wide box the stamp takes half the width, or up to 60% when it needs it; a signature at that height
      # needs far less than the remaining 40%.
      plan = (wide && SIDE_SHARES.lazy.filter_map do |share|
        plan_for(pdf, line_sets, id, (width - GAP) * share, height, MIN_FONT_SIZE, :side, fallback)
      end.first) ||
             plan_for(pdf, line_sets, id, width, height * 0.5, MIN_FONT_SIZE, :stacked, fallback) ||
             plan_for(pdf, line_sets, id, wide ? (width - GAP) * SIDE_SHARES.last : width,
                      wide ? height : height * 0.5, SMALL_BOX_MIN_FONT_SIZE, wide ? :side : :stacked, fallback)
      side_width = plan&.width

      image_box =
        case plan&.mode
        when :side then [left, top, width - side_width - GAP, height]
        when :stacked then [left, top, width, height - plan.height - 2]
        else [left, top, width, height]
        end

      draw_image(canvas, image, *image_box)

      return unless plan

      if plan.mode == :side
        draw_text(canvas, plan, left + width - side_width, top - ((height - plan.height) / 2.0))
      else
        draw_text(canvas, plan, left, top - height + plan.height)
      end

      plan
    end

    # Candidate texts, preferred first: the full prefix, the short prefix, then the short prefix with the name
    # shortened to fit (the name is given in full in the audit log and in the signature itself).
    def line_sets(pdf, signer, prefix, short_prefix, time, text_width, fallback)
      return [[time]] if signer.blank?

      sets = [["#{prefix} #{signer}", time], ["#{short_prefix} #{signer}", time]]

      name = signer.to_s
      too_wide = ->(text) { fragment(pdf, text, MIN_FONT_SIZE, INK, bold: true, fallback:).width > text_width }
      name = name[0..-2].rstrip while name.length > 12 && too_wide.call("#{short_prefix} #{name}…")
      sets << ["#{short_prefix} #{name}…", time] if name != signer.to_s

      sets.uniq
    end

    # The ID on one line, or split after its second group when the box is narrow.
    def id_lines(id)
      full = "ID #{id}".upcase
      parts = full.split('-')

      [[full], ["#{parts[0..1].join('-')}-", parts[2..].join('-')]]
    end

    def plan_for(pdf, line_sets, id, width, height, min_size, mode, fallback)
      text_width = width - RULE_GAP - 0.6

      return if text_width <= 0 || height <= 0

      line_sets.call(text_width).product(id_lines(id)).each do |lines, id_text|
        size = MAX_FONT_SIZE

        while size >= min_size
          result = HexaPDF::Layout::TextLayouter.new.fit(fragments(pdf, lines, id_text, size, fallback),
                                                         text_width, height)

          if result.status == :success && result.lines.size == lines.size + id_text.size
            return Plan.new(mode:, result:, font_size: size, width:, height: result.lines.sum(&:height))
          end

          size -= FONT_SIZE_STEP
        end
      end

      nil
    end

    def draw_image(canvas, image, left, top, width, height)
      return if width <= 0 || height <= 0

      scale = [width / image.width, height / image.height].min
      image_width = image.width * scale
      image_height = image.height * scale
      io = StringIO.new(image.resize([scale * 4, 1].select(&:positive?).min).write_to_buffer('.png', strip: true))

      canvas.image(io, at: [left + ((width - image_width) / 2.0), top - ((height + image_height) / 2.0)],
                       width: image_width, height: image_height)
    end

    def draw_text(canvas, plan, left, top)
      canvas.save_graphics_state do
        canvas.stroke_color(CORAL).line_width(0.6).line(left + 0.3, top, left + 0.3, top - plan.height).stroke
      end

      plan.result.draw(canvas, left + RULE_GAP + 0.6, top)
    end

    def font(pdf, text, bold: false, fallback: nil)
      font = pdf.fonts.add(bold ? BOLD_PATH : REGULAR_PATH)

      return font if covers?(font, text) || fallback.nil?

      pdf.fonts.add(fallback)
    end

    def covers?(font, text)
      cmap = font.wrapped_font[:cmap].preferred_table

      text.to_s.each_codepoint.all? { |codepoint| codepoint < 32 || cmap[codepoint] }
    end

    def fragments(pdf, lines, id_lines, font_size, fallback)
      signer, *rest = lines

      items = [fragment(pdf, signer, font_size, INK, bold: true, fallback:)]
      (rest + id_lines).each do |line|
        items.push(newline(pdf, font_size), fragment(pdf, line, font_size, MUTED, fallback:))
      end

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
