# frozen_string_literal: true

describe Stevensed::SignatureStamp do
  let(:pdf) { HexaPDF::Document.new }
  let(:page) { pdf.pages.add([0, 0, 612, 792]) }
  let(:lines) { ['Digitally signed by Alexandria Whitfield-Montgomery <registrar@example.org>', 'November 26, 2026'] }
  let(:id) { SecureRandom.uuid }

  def page_text
    io = StringIO.new
    pdf.write(io, validate: false)

    Pdfium::Document.open_bytes(io.string) { |doc| doc.get_page(0).text }
  end

  it 'fits the full stamp in a StevensED signature box' do
    size = described_class.draw(page.canvas(type: :overlay), pdf, left: 208, top: 434, width: 145, height: 22,
                                                                  id:, lines:)

    expect(size).to be >= described_class::MIN_FONT_SIZE
    expect(page_text.gsub(/\s+/, '')).to include("ID#{id.upcase}", 'Whitfield-Montgomery')
  end

  it 'leaves out what does not fit instead of drawing outside a very small box' do
    size = described_class.draw(page.canvas(type: :overlay), pdf, left: 72, top: 300, width: 40, height: 6, id:,
                                                                  lines:)

    expect(size).to be < described_class::MAX_FONT_SIZE
  end

  it 'uses the fallback font for scripts Inter does not cover' do
    inter = pdf.fonts.add(described_class::REGULAR_PATH)

    expect(described_class.covers?(inter, 'Zoë Łukasiewicz-Ngô')).to be(true)
    expect(described_class.covers?(inter, '山田太郎')).to be(false)
    expect(described_class.font(pdf, '山田太郎', fallback: 'Helvetica')).not_to eq(inter)
  end

  it 'draws the per-page line in the bottom margin' do
    described_class.draw_footer(page, pdf, described_class.footer_text('ABC123'))

    expect(page_text).to include("#{Stevensed::PRODUCT_NAME} · Document ID ABC123")
  end
end
