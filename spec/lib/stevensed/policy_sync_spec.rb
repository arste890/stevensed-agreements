# frozen_string_literal: true

describe Stevensed::PolicySync do
  let(:account) { create(:account) }
  let(:today) { Date.new(2026, 11, 26) }

  let(:pdf) do
    doc = HexaPDF::Document.new
    doc.pages.add([0, 0, 612, 792]).canvas.font('Helvetica', size: 12).text('Test form', at: [72, 720])
    io = StringIO.new
    doc.write(io)
    io.string
  end

  let(:field_map) do
    { 'name' => 'Test', 'fields' => [
      { 'name' => 'Full legal name', 'type' => 'text', 'role' => 'Parent', 'required' => true,
        'areas' => [{ 'page' => 1, 'x' => 61.2, 'y' => 79.2, 'w' => 306, 'h' => 19.8 }] },
      { 'name' => 'Parent signature', 'type' => 'signature', 'role' => 'Parent', 'required' => true,
        'areas' => [{ 'page' => 1, 'x' => 61.2, 'y' => 158.4, 'w' => 200, 'h' => 40 }] }
    ] }
  end

  let(:manifest) do
    { 'forms' => {
      'FRM-102-M' => { 'id' => 'FRM-102', 'title' => 'Electronic Records and Signature Consent', 'audience' => 'minor',
                       'versions' => {
                         '3.0' => { 'effective' => '2026-08-24', 'file' => 'forms/pdf/old.pdf', 'sha256' => 'x' },
                         '2.3' => version('2026-08-24'),
                         '2.4' => version('2026-11-05'),
                         '4.0' => version('2026-12-01'),
                         '4.1' => version('2026-12-01')
                       } }
    } }
  end

  let(:responses) do
    { described_class::MANIFEST_PATH => manifest.to_json, described_class::ENVELOPES_PATH => '{}',
      'forms/docuseal/map.json' => field_map.to_json, 'forms/pdf/form.pdf' => pdf }
  end

  let(:http) { ->(path) { responses.fetch(path) } }

  before { create(:user, account:, role: User::ADMIN_ROLE) }

  def version(effective, map: 'forms/docuseal/map.json', sha: Digest::SHA256.hexdigest(pdf))
    { 'effective' => effective, 'file' => 'forms/pdf/form.pdf', 'sha256' => sha, 'docuseal' => { 'file' => map } }
  end

  it 'keeps the version in effect and the later version, ignoring unmapped and superseded ones' do
    plan = described_class.call(apply: false, today:, http:)

    expect(plan[:created]).to eq(%w[FRM-102-M_v2.4 FRM-102-M_v4.1])
    expect(Template.count).to eq(0)
  end

  it 'creates templates with fields placed as fractions of the page' do
    described_class.call(apply: true, today:, http:)

    template = Template.find_by!(external_id: 'FRM-102-M_v4.1')
    field = template.fields.find { |f| f['name'] == 'Full legal name' }

    expect(template.name).to eq('FRM-102 Electronic Records and Signature Consent (Minor Student) v4.1 ' \
                                '(from December 1, 2026)')
    expect(template.submitters.pluck('name')).to eq(['Parent'])
    expect(template.documents.count).to eq(1)
    expect(field['areas'].first['page']).to eq(0)
    expect(field['areas'].first.slice('x', 'y', 'w', 'h').transform_values { |v| v.round(6) })
      .to eq('x' => 0.1, 'y' => 0.1, 'w' => 0.5, 'h' => 0.025)
    expect(template.preferences.dig(described_class::PREFERENCE_KEY, 'version')).to eq('4.1')
  end

  it 'archives a superseded version once the new one takes effect, and creates nothing twice' do
    described_class.call(apply: true, today:, http:)
    plan = described_class.call(apply: true, today: Date.new(2026, 12, 1), http:)

    expect(plan[:created]).to be_empty
    expect(plan[:archived].map(&:second)).to eq(['FRM-102-M_v2.4'])
    expect(Template.find_by!(external_id: 'FRM-102-M_v2.4').archived_at).to be_present
  end

  it 'refuses a file whose checksum does not match the manifest' do
    manifest['forms']['FRM-102-M']['versions']['4.1'] = version('2026-12-01', sha: 'f' * 64)

    expect { described_class.call(apply: true, today:, http:) }.to raise_error(/SHA-256/)
  end
end
