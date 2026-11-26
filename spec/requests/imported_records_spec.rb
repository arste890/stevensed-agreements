# frozen_string_literal: true

describe 'Imported records' do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:root) { Pathname.new(Dir.mktmpdir) }

  before do
    stub_const('ImportedRecordsController::ROOT', root)

    record = root.join('13478070')
    FileUtils.mkdir_p(record)
    File.write(record.join('metadata.json'), {
      template: { name: 'FRM-108 Parental Consent for Online Services (Student Under 13) v4.6' },
      completed_at: '2026-11-22T17:04:11Z',
      submitters: [
        { role: 'StevensED', name: nil, email: 'records@stevensed.org' },
        { role: 'Parent', name: 'Janey Archibald', email: 'janey@example.com' }
      ],
      files: {
        'combined.pdf' => 'a1', 'audit-log.pdf' => 'b2',
        'FRM-108 Parental Consent for Online Services (Student Under 13) v4.6.pdf' => 'c3'
      },
      verified_against_audit_log: { 'combined.pdf' => true, 'audit-log.pdf' => true }
    }.to_json)
    File.write(record.join('combined.pdf'), '%PDF-1.7')
    File.write(root.join('secret.pdf'), '%PDF-1.7')

    sign_in(user)
  end

  after { FileUtils.rm_rf(root) }

  it 'lists downloads with short labels in a fixed order and StevensED last among the signers' do
    get settings_imported_records_path

    body = response.body

    expect(response).to have_http_status(:ok)
    expect(body.index('Signed document')).to be < body.index('Audit log')
    expect(body.index('Audit log')).to be < body.index('Combined PDF')
    expect(body.index('janey@example.com')).to be < body.index('records@stevensed.org')
    expect(body).to include('Completed 22 November 2026')
    expect(body).to include('Verified against the original audit log, envelope 13478070')
  end

  it 'serves only files listed in the record metadata' do
    get settings_imported_record_path('13478070', file: 'combined.pdf')

    expect(response).to have_http_status(:ok)

    expect do
      get settings_imported_record_path('13478070', file: '../secret.pdf')
    end.to raise_error(ActiveRecord::RecordNotFound)
  end
end
