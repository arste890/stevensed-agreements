# frozen_string_literal: true

describe Stevensed::Retention do
  let(:account) { create(:account, timezone: 'America/Denver') }
  let(:staff) { create(:user, account:, role: User::ADMIN_ROLE, email: 'legal@example.org') }
  let(:frm105_fields) do
    [['Parent', 'text', '1. Legal name'], ['Parent', 'text', '6. Allergies (food, medication, insect, latex, other)']]
  end
  let(:frm105) do
    stevensed_form_template(account:, author: staff, external_id: 'FRM-105-M_v4.1', fields: frm105_fields)
  end

  def signed_frm105(completed_at)
    stevensed_envelope(frm105, family_email: 'pat@family.test', staff_email: staff.email, completed_at:,
                               values: { '1. Legal name' => 'Sam Student',
                                         '6. Allergies (food, medication, insect, latex, other)' => 'Peanuts' })
  end

  describe 'period' do
    it 'ends 3 years after 31 August of the academic year the form covers' do
      expect(described_class.academic_year_end(Date.new(2026, 10, 1))).to eq(Date.new(2027, 8, 31))
      expect(described_class.academic_year_end(Date.new(2027, 3, 1))).to eq(Date.new(2027, 8, 31))
    end

    it 'treats a form completed from 1 June as covering the next academic year, so it is never disposed of early' do
      expect(described_class.academic_year_end(Date.new(2027, 6, 1))).to eq(Date.new(2028, 8, 31))
    end

    it 'adds 3 years to the end of that academic year' do
      submission = signed_frm105(Time.zone.parse('2026-10-01 12:00'))

      expect(described_class.frm105_period_end(submission)).to eq(Date.new(2030, 8, 31))
    end
  end

  describe 'sweep' do
    it 'only reports by default' do
      submission = signed_frm105(Time.zone.parse('2026-10-01 12:00'))

      result = described_class.sweep(today: Date.new(2030, 9, 1))

      expect(result['due']).to eq([{ 'submission_id' => submission.id, 'period_ended_on' => '2030-08-31' }])
      expect(Submission.exists?(submission.id)).to be(true)
    end

    it 'keeps a record whose period has not ended' do
      submission = signed_frm105(Time.zone.parse('2026-10-01 12:00'))

      result = described_class.sweep(apply: true, today: Date.new(2030, 8, 31))

      expect(result['counts']['disposed']).to eq(0)
      expect(Submission.exists?(submission.id)).to be(true)
    end

    it 'disposes of an expired record and keeps a disposal record without personal data' do
      submission = signed_frm105(Time.zone.parse('2026-10-01 12:00'))
      document_id = Digest::MD5.hexdigest(submission.slug).upcase
      consent = StevensedEsignConsent.create!(account:, email: 'pat@family.test', kind: 'family_minor',
                                              form_key: 'FRM-102-M', legal_name: 'Pat Parent',
                                              signed_at: Time.current, source: 'signed',
                                              submission:, submitter: submission.submitters.first)

      result = described_class.sweep(apply: true, today: Date.new(2030, 9, 1))

      expect(result['counts']['disposed']).to eq(1)
      expect(Submission.exists?(submission.id)).to be(false)
      expect(Submitter.where(submission_id: submission.id)).to be_empty

      disposal = StevensedRetentionDisposal.find_by!(submission_id: submission.id)
      expect(disposal).to have_attributes(document_id:, form_key: 'FRM-105-M', form_version: '4.1',
                                          completed_on: Date.new(2026, 10, 1),
                                          period_ended_on: Date.new(2030, 8, 31), rule: described_class::RULE_FRM105)
      expect(disposal.attributes.to_json).not_to include('Sam Student', 'Peanuts', 'pat@family.test')

      expect(consent.reload).to have_attributes(submission_id: nil, submitter_id: nil, legal_name: 'Pat Parent')
    end

    it 'never disposes of a record on a litigation hold' do
      submission = signed_frm105(Time.zone.parse('2026-10-01 12:00'))
      described_class.place_hold!(submission, user: staff, note: 'Matter 2030-04')

      result = described_class.sweep(apply: true, today: Date.new(2031, 1, 1))

      expect(result['held'].pluck('submission_id')).to eq([submission.id])
      expect(Submission.exists?(submission.id)).to be(true)
      expect { described_class.dispose!(submission, period_end: Date.new(2030, 8, 31)) }
        .to raise_error(ArgumentError)
    end

    it 'disposes of a record once its hold is released' do
      submission = signed_frm105(Time.zone.parse('2026-10-01 12:00'))
      described_class.place_hold!(submission, user: staff, note: 'Matter 2030-04')
      described_class.release_hold!(submission.reload, user: staff)

      expect(submission.submission_events.pluck(:event_type)).to include('stevensed_hold_placed',
                                                                         'stevensed_hold_released')

      described_class.sweep(apply: true, today: Date.new(2031, 1, 1))

      expect(Submission.exists?(submission.id)).to be(false)
    end

    it 'leaves an unfinished record alone' do
      submission = signed_frm105(Time.zone.parse('2026-10-01 12:00'))
      submission.submitters.first.update!(completed_at: nil)

      result = described_class.sweep(apply: true, today: Date.new(2031, 1, 1))

      expect(result['counts'].values.sum).to eq(0)
      expect(Submission.exists?(submission.id)).to be(true)
    end

    it 'reports, and never changes, a combined envelope that holds FRM-105 pages' do
      envelope = stevensed_form_template(account:, author: staff, external_id: 'First-Time-Enrollment-M@abc123',
                                         fields: [['Parent', 'text', '103 1. Student name'],
                                                  ['Parent', 'text', '105 6. Allergies']])
      submission = stevensed_envelope(envelope, family_email: 'pat@family.test', staff_email: staff.email,
                                                completed_at: Time.zone.parse('2026-10-01 12:00'))

      result = described_class.sweep(apply: true, today: Date.new(2031, 1, 1))

      expect(result['envelopes_for_decision'].pluck('submission_id')).to eq([submission.id])
      expect(Submission.exists?(submission.id)).to be(true)
    end

    it 'ignores other forms' do
      other = stevensed_form_template(account:, author: staff, external_id: 'FRM-103-M_v7.1',
                                      fields: [['Parent', 'text', '1. Student name']])
      submission = stevensed_envelope(other, family_email: 'pat@family.test', staff_email: staff.email,
                                             completed_at: Time.zone.parse('2020-10-01 12:00'))

      result = described_class.sweep(apply: true, today: Date.new(2031, 1, 1))

      expect(result['counts'].values.sum).to eq(0)
      expect(Submission.exists?(submission.id)).to be(true)
    end
  end
end
