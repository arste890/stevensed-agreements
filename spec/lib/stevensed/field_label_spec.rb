# frozen_string_literal: true

describe Stevensed::FieldLabel do
  it 'leaves out leading section numbers' do
    expect(described_class.display('10. Full legal name')).to eq('Full legal name')
    expect(described_class.display('9. I confirm I can open and save this')).to eq('I confirm I can open and save this')
    expect(described_class.display('4a) Student')).to eq('Student')
    expect(described_class.display('Parent — Signature')).to eq('Parent — Signature')
    expect(described_class.display('2026 tuition')).to eq('2026 tuition')
  end
end
