# frozen_string_literal: true

describe Stevensed::IdentityEvents do
  let(:account) { create(:account) }
  let(:staff) { create(:user, account:, role: User::ADMIN_ROLE, email: 'legal@example.org') }
  let(:frm108) do
    stevensed_form_template(account:, author: staff, external_id: 'FRM-108_v4.9', fields: StevensedIdentityHelper::FRM108_FIELDS)
  end
  let(:section11) do
    { '11. Parent consent verified by StevensED staff on (date)' => '2026-11-20',
      '11. StevensED staff member' => 'Alec Stevens', '11. Form version' => '4.9',
      '11. StevensED use only' => 'Video call or in person' }
  end
  let(:parent_values) do
    { '1. Student legal name' => 'Sam Student', '1. Student date of birth' => '2016-04-03',
      '1. Parent/guardian full name' => 'Pat Parent', '1. Parent/guardian email on file' => 'Pat@Family.test',
      '9. Your choice' => 'I consent' }
  end

  around do |example|
    with_env(described_class::URL_ENV => 'https://idp.test/api/v1/agreements/events',
             described_class::SECRET_ENV => 'test-shared-secret') { example.run }
  end

  describe '.build' do
    it 'carries references, links and the FRM-108 section 11 facts, and never a full date of birth' do
      submission = stevensed_envelope(frm108, family_email: 'pat@family.test', staff_email: staff.email,
                                              values: parent_values.merge(section11),
                                              metadata: { 'stevensed_student_id' => 'u_kid',
                                                          'stevensed_household_id' => 'h_1' })

      event = described_class.build('envelope.completed', submission, event_id: "agr_#{submission.id}_completed")

      expect(event['envelope']).to include('id' => submission.id, 'form_key' => 'FRM-108', 'form' => 'FRM-108',
                                           'form_version' => '4.9',
                                           'document_id' => Digest::MD5.hexdigest(submission.slug).upcase)
      expect(event['links']).to eq('student_id' => 'u_kid', 'household_id' => 'h_1')
      expect(event['facts']).to include('student_name' => 'Sam Student', 'student_birth_year' => 2016,
                                        'parent_email' => 'pat@family.test', 'choice' => 'consent',
                                        'section_11_complete' => true)
      expect(event['facts']['section_11']).to eq('verified_on' => '2026-11-20', 'staff' => 'Alec Stevens',
                                                 'form_version' => '4.9', 'method_label' => 'Video call or in person',
                                                 'method' => 'video')
      expect(event['signers'].map { |s| s.slice('role', 'staff') })
        .to eq([{ 'role' => 'Parent', 'staff' => false }, { 'role' => 'StevensED', 'staff' => true }])
      expect(event.to_json).not_to include('2016-04-03')
    end

    it 'marks section 11 incomplete when the StevensED official left it blank' do
      submission = stevensed_envelope(frm108, family_email: 'pat@family.test', staff_email: staff.email,
                                              values: parent_values.merge('11. StevensED staff member' => 'Alec'))

      facts = described_class.build('envelope.completed', submission, event_id: 'x')['facts']

      expect(facts['section_11_complete']).to be(false)
    end

    it 'passes only the birth year from FRM-101' do
      frm101 = stevensed_form_template(account:, author: staff, external_id: 'FRM-101-M_v3.1',
                                       fields: StevensedIdentityHelper::FRM101_FIELDS)
      submission = stevensed_envelope(frm101, family_email: 'pat@family.test', staff_email: staff.email,
                                              values: { '1. Applicant name' => 'Sam Student',
                                                        '1. Applicant date of birth' => '2014-09-30' })

      event = described_class.build('envelope.completed', submission, event_id: 'x')

      expect(event['envelope']).to include('form' => 'FRM-101', 'form_key' => 'FRM-101-M')
      expect(event['facts']).to eq('student_name' => 'Sam Student', 'birth_year' => 2014)
    end
  end

  describe 'enqueueing' do
    it 'queues a completion for a form identity acts on, and nothing for other forms' do
      submission = stevensed_envelope(frm108, family_email: 'pat@family.test', staff_email: staff.email)
      other = stevensed_form_template(account:, author: staff, external_id: 'FRM-301_v1.0',
                                      fields: StevensedIdentityHelper::FRM101_FIELDS)

      expect { described_class.enqueue_completed(submission) }.to change(StevensedIdentityEventJob.jobs, :size).by(1)
      expect(StevensedIdentityEventJob.jobs.last['args'].first)
        .to include('type' => 'envelope.completed', 'event_id' => "agr_#{submission.id}_completed")

      expect do
        described_class.enqueue_completed(stevensed_envelope(other, family_email: 'a@b.test', staff_email: staff.email))
      end.not_to change(StevensedIdentityEventJob.jobs, :size)
    end

    it 'queues nothing when the channel is not configured' do
      submission = stevensed_envelope(frm108, family_email: 'pat@family.test', staff_email: staff.email)

      with_env(described_class::SECRET_ENV => '') do
        expect { described_class.enqueue_completed(submission) }.not_to change(StevensedIdentityEventJob.jobs, :size)
      end
    end

    it 'queues an archive only when staff archived it with a reason' do
      submission = stevensed_envelope(frm108, family_email: 'pat@family.test', staff_email: staff.email)
      Stevensed::Records.archive_by_staff!(submission, user: staff, reason: 'withdrawn', note: 'Parent withdrew')

      expect do
        described_class.enqueue_archived(submission.reload)
      end.to change(StevensedIdentityEventJob.jobs, :size).by(1)
      expect(described_class.build('envelope.archived', submission, event_id: 'x')['archived'])
        .to include('reason' => 'withdrawn', 'note' => 'Parent withdrew')
    end
  end

  describe 'signing' do
    it 'signs "<timestamp>.<body>" with HMAC-SHA256' do
      headers = described_class.headers_for('{"a":1}', event_id: 'evt', now: Time.zone.at(1_800_000_000))

      expect(headers).to include('X-StevensED-Timestamp' => '1800000000', 'X-StevensED-Event-Id' => 'evt')
      expect(headers['X-StevensED-Signature'])
        .to eq("v1=#{OpenSSL::HMAC.hexdigest('SHA256', 'test-shared-secret', '1800000000.{"a":1}')}")
    end
  end
end
