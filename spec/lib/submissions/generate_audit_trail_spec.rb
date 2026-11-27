# frozen_string_literal: true

describe Submissions::GenerateAuditTrail do
  let(:account) { create(:account, timezone: 'Mountain Time (US & Canada)') }
  let(:author) { create(:user, account:) }
  let(:template) do
    create(:template, account:, author:, submitter_count: 2, attachment_count: 1,
                      only_field_types: %w[text date])
  end
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: author) }

  before do
    create(:encrypted_config, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))

    submission.submitters.each_with_index do |submitter, index|
      submitter.update!(completed_at: Time.current - (10 - index).minutes, timezone: 'America/Denver')
      SubmissionEvent.create!(submitter:, submission:, event_type: :complete_form,
                              event_timestamp: submitter.completed_at,
                              data: { ip: "198.51.100.#{index + 10}", ua: 'Mozilla/5.0 RSpec' })
    end
  end

  def pdf_text(document)
    io = StringIO.new
    document.write(io, validate: false)

    Pdfium::Document.open_bytes(io.string) do |doc|
      Array.new(doc.page_count) { |i| doc.get_page(i).then { |page| page.text.tap { page.close } } }
    end
  end

  def build
    described_class.build_audit_trail(submission.reload)
  end

  it 'renders the StevensED header, sections and footer' do
    pages = pdf_text(build)
    text = pages.join("\n")

    expect(text).to include(Stevensed::PRODUCT_NAME)
    expect(text).to include(Stevensed::OFFICE.upcase)
    expect(text).to include(I18n.t('audit_log'))
    expect(text).to include('Signers', I18n.t('event_log'), 'Signing certificate')
    expect(text).to include('198.51.100.10')
    expect(text).to include("Page 1 of #{pages.size}")
    expect(text).to include("#{I18n.t('envelope_id')} #{submission.id}")
    expect(text).to include('pki.stevensed.org')
    expect(text).not_to include('DocuSeal')
  end

  it 'summarises the signing certificate without private material' do
    text = pdf_text(build).join("\n")
    certificate = Accounts.load_signing_pkcs(account).certificate

    serial = certificate.serial.to_s(16).upcase.then { |hex| hex.length.odd? ? "0#{hex}" : hex }

    expect(text.gsub(/\s+/, '')).to include(serial.scan(/../).join(':'))
    expect(text.gsub(/\s+/, '')).to include(OpenSSL::Digest::SHA256.hexdigest(certificate.to_der).upcase
                                                                   .scan(/../).join(':'))
    expect(text).to include('CERTIFICATE', 'DETAIL', 'SHA-256 FINGERPRINT')
    expect(text).not_to match(/PRIVATE KEY|password/i)
  end

  it 'splits the fingerprint into two even halves of 16 bytes' do
    text = pdf_text(build).join("\n")
    bytes = OpenSSL::Digest::SHA256.hexdigest(Accounts.load_signing_pkcs(account).certificate.to_der).upcase.scan(/../)

    expect(text).to include("#{bytes[0, 16].join(':')}:\n#{bytes[16, 16].join(':')}")
      .or include("#{bytes[0, 16].join(':')}:\r\n#{bytes[16, 16].join(':')}")
  end

  it 'repeats a running header on continuation pages and sets every label in capitals' do
    pages = pdf_text(build)
    header = "#{Stevensed::PRODUCT_NAME} · #{I18n.t('audit_log')} · Envelope #{submission.id}"

    expect(pages.first).not_to include(header)
    expect(pages.drop(1)).to all(include(header)) if pages.size > 1
    expect(pages.join("\n")).to include('IP ADDRESS', 'USER AGENT', 'TIME ZONE')
    expect(pages.join("\n")).not_to include('IP address:', 'User agent:')
  end

  it 'repeats the event log header row on every page and never leaves fewer than three rows on one' do
    submitter = submission.submitters.first
    60.times do |index|
      SubmissionEvent.create!(submitter:, submission:, event_type: :view_form,
                              event_timestamp: submitter.completed_at + index.minutes)
    end

    pages = pdf_text(build)
    log_pages = pages.select { |page| page.include?('Form viewed by') }

    expect(log_pages.size).to be > 1
    log_pages.each do |page|
      expect(page).to include('DATE TIME EVENT')
      expect(page.scan('Form viewed by').size).to be >= Submissions::GenerateAuditTrail::MIN_ROWS
    end
  end

  it 'splits document hashes by character and hexadecimal values by whole bytes' do
    expect(described_class.even_halves(('A' * 22) + ('B' * 22))).to eq("#{'A' * 22}\n#{'B' * 22}")
    expect(described_class.hex_bytes('ABC')).to eq('0A:BC')
  end

  it 'embeds the brand fonts' do
    font_names = build.each(only_loaded: false).filter_map do |obj|
      obj[:BaseFont].to_s if obj.is_a?(HexaPDF::Dictionary) && obj[:Type] == :Font
    end

    expect(font_names.join(' ')).to include('Inter', 'CormorantGaramond', 'DejaVuSansMono')
  end

  it 'names each signer by legal name and leaves section numbers out of field labels' do
    signer = submission.submitters.first
    StevensedEsignConsent.create!(account:, submission:, submitter: signer, email: signer.email, kind: 'general',
                                  form_key: 'FRM-102-A', legal_name: 'Testa Q. Signer', signed_at: Time.current,
                                  source: 'signed')
    field = submission.template_fields.find { |f| f['submitter_uuid'] == signer.uuid && f['type'] == 'text' }
    field['name'] = "10. #{field['name']}"
    submission.update!(template_fields: submission.template_fields)
    signer.update!(values: signer.values.merge(field['uuid'] => 'Entered value'))

    text = pdf_text(build).join("\n")

    expect(text).to include('Testa Q. Signer')
    expect(text).to include(field['name'].delete_prefix('10. '), 'FIELD', 'ENTRY')
    expect(text).not_to include('10. ')
  end

  it 'writes dates as day, month name and year' do
    text = pdf_text(build).join("\n")

    completed_at = submission.submitters.first.completed_at.in_time_zone(account.timezone)

    expect(text).to include(Stevensed.format_date(completed_at))
    expect(text).to match(/\b\d{1,2} [A-Z][a-z]+ \d{4}, \d{1,2}:\d{2} [AP]M/)
  end

  it 'uses Letter for US time zones and A4 elsewhere' do
    expect(build.pages.first.box(:media).height).to eq(792)

    account.update!(timezone: 'Berlin')

    expect(build.pages.first.box(:media).height).to be_within(1).of(841.89)
  end
end
