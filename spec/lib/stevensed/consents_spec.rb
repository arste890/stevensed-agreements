# frozen_string_literal: true

describe Stevensed::Consents do
  let(:account) { create(:account) }
  let(:author) { create(:user, account:, role: User::ADMIN_ROLE) }
  let(:request) do
    instance_double(ActionDispatch::Request, remote_ip: '127.0.0.1', user_agent: 'RSpec',
                                             session: instance_double(ActionDispatch::Request::Session, id: 'sid'),
                                             env: { 'warden' => instance_double(Warden::Proxy, user: nil) })
  end

  def field(name, type, role_uuid)
    { 'uuid' => SecureRandom.uuid, 'name' => name, 'type' => type, 'required' => true, 'submitter_uuid' => role_uuid,
      'areas' => [] }
  end

  def build_template(external_id:, roles:, fields: ->(_uuids) { [] }, name: nil)
    template = create(:template, account:, author:, only_field_types: %w[text])
    submitters = roles.map { |r| { 'name' => r, 'uuid' => SecureRandom.uuid } }
    uuids = submitters.to_h { |s| [s['name'], s['uuid']] }
    template.update!(external_id:, submitters:, fields: fields.call(uuids), name: name || external_id)
    template
  end

  def signer_for(template, role, email: 'pat@example.org', esign_consent: false)
    submission = create(:submission, template:, created_by_user: author)
    uuid = template.submitters.find { |s| s['name'] == role }['uuid']
    create(:submitter, submission:, uuid:, account:, email:, name: 'Pat', esign_consent:)
  end

  let(:frm102m) do
    build_template(external_id: 'FRM-102-M_v4.1', roles: ['Parent'], fields: lambda { |u|
      [field('10. Full legal name', 'text', u['Parent']),
       field('10. Email address for records and notices', 'text', u['Parent']),
       field('Parent — Printed name', 'text', u['Parent'])]
    })
  end

  let(:frm103m) do
    build_template(external_id: 'FRM-103-M_v7.1', roles: ['Parent', 'Parent 2', 'StevensED'], fields: lambda { |u|
      [field('Parent — Printed name', 'text', u['Parent']), field('1. Student date of birth', 'date', u['Parent'])]
    })
  end

  describe '.context and .band_matches?' do
    it 'classifies family, staff and general envelopes and their versions' do
      expect(described_class.context(signer_for(frm103m, 'Parent')).to_h)
        .to include(audience: 'family', variant: 'minor', minor_signer: false)
      expect(described_class.context(signer_for(frm103m, 'StevensED')).audience).to eq('staff')

      offer = build_template(external_id: nil, roles: %w[Employer Candidate], name: 'Offer Letter')
      expect(described_class.context(signer_for(offer, 'Candidate')).audience).to eq('general')

      acknowledgment = build_template(external_id: 'FRM-106-M_v6.1', roles: %w[Parent Student])
      expect(described_class.context(signer_for(acknowledgment, 'Student')).minor_signer).to be(true)
    end

    it 'matches the student age band to the envelope version' do
      minor = described_class::Context.new(variant: 'minor', packet: false)
      minor_packet = described_class::Context.new(variant: 'minor', packet: true)
      child = described_class::Context.new(variant: 'child', packet: false)
      adult = described_class::Context.new(variant: 'adult', packet: false)

      expect(described_class.band_matches?(minor, 'under_13')).to be(true)
      expect(described_class.band_matches?(minor, 'adult')).to be(false)
      expect(described_class.band_matches?(minor_packet, 'under_13')).to be(false)
      expect(described_class.band_matches?(child, 'under_18')).to be(false)
      expect(described_class.band_matches?(adult, 'adult')).to be(true)
      expect(described_class.age_band(Date.new(2008, 11, 27), today: Date.new(2026, 11, 26))).to eq('under_18')
      expect(described_class.age_band(Date.new(2008, 11, 26), today: Date.new(2026, 11, 26))).to eq('adult')
    end
  end

  describe '.prepare' do
    it 'asks a family signer for the student date of birth, then for the consent form' do
      frm102m
      signer = signer_for(frm103m, 'Parent')

      expect(described_class.prepare(signer, request)).to eq(:dob)

      described_class.store_age!(signer, Date.new(2015, 3, 1), 'under_13')
      dob_field = signer.submission.template_fields.find { |f| f['type'] == 'date' }

      expect(signer.reload.values[dob_field['uuid']]).to eq('2015-03-01')
      expect(described_class.prepare(signer, request)).to eq(:sign_consent)
    end

    it 'falls back to the checkbox when no consent form is published' do
      signer = signer_for(build_template(external_id: nil, roles: ['Candidate'], name: 'Offer Letter'), 'Candidate')

      expect(described_class.prepare(signer, request)).to eq(:checkbox)
    end

    it 'accepts a consent on file, records it in the audit event and carries the legal name' do
      signer = signer_for(frm103m, 'Parent', email: 'Pat@Example.org')
      described_class.store_age!(signer, Date.new(2012, 1, 1), 'under_18')
      StevensedEsignConsent.create!(account:, email: 'pat@example.org', kind: 'family_minor', form_key: 'FRM-102-M',
                                    form_version: '4.1', legal_name: 'Patricia Q. Example', source: 'manual',
                                    signed_at: 1.day.ago)

      expect(described_class.prepare(signer, request)).to eq(:none)

      event = signer.submission_events.find_by!(event_type: :accept_esign_consent)
      name_field = signer.submission.reload.template_fields.find { |f| f['name'] == 'Parent — Printed name' }

      expect(event.data).to include('consent_form' => 'FRM-102-M v4.1', 'student_age' => 'under_18')
      expect(signer.reload.name).to eq('Patricia Q. Example')
      expect(signer.values[name_field['uuid']]).to eq('Patricia Q. Example')
      expect(name_field['readonly']).to be(true)
      expect(described_class.audit_line(event)).to include('FRM-102-M v4.1', 'Student age confirmed: 13 to 17')
    end

    it 'ignores a withdrawn consent' do
      frm102m
      signer = signer_for(frm103m, 'Parent')
      described_class.store_age!(signer, Date.new(2012, 1, 1), 'under_18')
      StevensedEsignConsent.create!(account:, email: signer.email, kind: 'family_minor', form_key: 'FRM-102-M',
                                    legal_name: 'Pat', source: 'manual', signed_at: 1.day.ago,
                                    withdrawn_at: Time.current)

      expect(described_class.prepare(signer, request)).to eq(:sign_consent)
    end

    it 'lets a minor student sign only once a parent consent is on file, and asks the parent otherwise' do
      frm102m
      template = build_template(external_id: 'FRM-106-M_v6.1', roles: %w[Parent Student])
      submission = create(:submission, template:, created_by_user: author)
      parent = create(:submitter, submission:, uuid: template.submitters.first['uuid'], account:,
                                  email: 'parent@example.org')
      student = create(:submitter, submission:, uuid: template.submitters.second['uuid'], account:,
                                   email: 'student@example.org', esign_consent: false)
      parent.submission_events.destroy_all

      expect(described_class.prepare(student, request)).to eq(:parent_required)
      expect(Submitter.where(email: 'parent@example.org').joins(:submission)
                      .exists?(submissions: { template_id: frm102m.id })).to be(true)

      StevensedEsignConsent.create!(account:, email: 'parent@example.org', kind: 'family_minor', form_key: 'FRM-102-M',
                                    legal_name: 'Parent Example', source: 'manual', signed_at: 1.day.ago)

      expect(described_class.prepare(student, request)).to eq(:none)
      expect(student.submission_events.find_by!(event_type: :accept_esign_consent).data['via_parent']).to be(true)
    end
  end

  describe '.start_consent! and .record_from_submitter' do
    it 'opens the consent form for the signer and registers it with the legal name when signed' do
      frm102m
      signer = signer_for(frm103m, 'Parent')
      consent_signer = described_class.start_consent!(signer, 'family_minor', 'https://example.org/s/back')
      name_field = frm102m.fields.find { |f| f['name'] == '10. Full legal name' }

      expect(consent_signer.submission.template).to eq(frm102m)
      expect(consent_signer.preferences['completed_redirect_url']).to eq('https://example.org/s/back')
      expect(described_class.start_consent!(signer, 'family_minor', 'https://example.org/s/back')).to eq(consent_signer)

      consent_signer.update!(completed_at: Time.current,
                             values: consent_signer.values.merge(name_field['uuid'] => 'Patricia Example'))
      consent = described_class.record_from_submitter(consent_signer)

      expect(consent).to have_attributes(kind: 'family_minor', form_key: 'FRM-102-M', form_version: '4.1',
                                         legal_name: 'Patricia Example', email: 'pat@example.org', source: 'signed')
      expect(described_class.on_file(account, 'PAT@example.org', ['family_adult'])).to eq(consent)
    end
  end
end
