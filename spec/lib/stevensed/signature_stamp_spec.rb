# frozen_string_literal: true

describe Stevensed::SignatureStamp do
  let(:pdf) { HexaPDF::Document.new }
  let(:page) { pdf.pages.add([0, 0, 612, 792]) }
  let(:image) { Vips::Image.black(600, 120).new_from_image([31, 41, 72]).bandjoin(Vips::Image.black(600, 120) + 255) }
  let(:id) { SecureRandom.uuid }

  def place(width:, height:, signer: 'Jordan Reyes', left: 61, top: 434)
    described_class.place(page.canvas(type: :overlay), pdf, image:, box: [left, top, width, height], id:, signer:,
                                                            prefix: 'Digitally signed by', short_prefix: 'Signed by',
                                                            time: 'November 26, 2026 at 12:46 PM MST')
  end

  def page_text
    io = StringIO.new
    pdf.write(io, validate: false)

    Pdfium::Document.open_bytes(io.string) { |doc| doc.get_page(0).text }
  end

  it 'sets the stamp beside the signature at 6 pt or more in a StevensED signature box (294 by 22 pt)' do
    plan = place(width: 293.64, height: 22)

    expect(plan.mode).to eq(:side)
    expect(plan.font_size).to be >= 6
    expect(page_text.gsub(/\s+/, '')).to include('DigitallysignedbyJordanReyes', "ID#{id.upcase}")
  end

  it 'keeps a long name legible by using the short prefix, then shortening the name in the stamp' do
    plan = place(width: 293.64, height: 22, signer: 'Alexandria Whitfield-Montgomery-Vanderbilt')

    expect(plan.font_size).to be >= 6
    expect(page_text).to include('Signed by Alexandria')
  end

  it 'stacks the stamp under the signature in a tall narrow box' do
    plan = place(width: 120, height: 70)

    expect(plan.mode).to eq(:stacked)
    expect(plan.font_size).to be >= 6
    expect(plan.height).to be < 70 * 0.5
  end

  it 'stays inside a box too small for 6 pt' do
    plan = place(width: 90, height: 12)

    expect(plan.nil? || plan.height <= 12).to be(true)
  end

  it 'shows only the time and ID when the signer line is turned off' do
    place(width: 293.64, height: 22, signer: nil)

    expect(page_text).to include('November 26, 2026', 'ID ')
    expect(page_text).not_to include('signed by')
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
