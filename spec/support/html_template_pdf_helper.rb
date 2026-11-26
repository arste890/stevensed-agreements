# frozen_string_literal: true

# StevensED: builds PDFs that stand in for Gotenberg output in HTML template specs.
module HtmlTemplatePdfHelper
  # markers: [[text, x, y]] in PDF points from the bottom left of a US Letter page.
  def html_template_pdf(markers = [])
    doc = HexaPDF::Document.new
    canvas = doc.pages.add([0, 0, 612, 792]).canvas

    canvas.font('Helvetica', size: 10)
    canvas.text('Enrollment agreement', at: [72, 740])

    canvas.font('Helvetica', size: 5)
    markers.each { |text, x, y| canvas.text(text, at: [x, y]) }

    io = StringIO.new
    doc.write(io)
    io.string
  end

  def stub_gotenberg_html_conversion(markers)
    marked_pdf = html_template_pdf(markers)
    final_pdf = html_template_pdf

    allow(Stevensed::Gotenberg).to receive(:html_to_pdf) do |html, **|
      html.include?('QZ0SZ') ? marked_pdf : final_pdf
    end
  end
end

RSpec.configure do |config|
  config.include HtmlTemplatePdfHelper
end
