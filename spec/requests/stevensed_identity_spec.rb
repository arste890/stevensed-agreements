# frozen_string_literal: true

describe 'StevensED identity endpoints' do
  let(:account) { create(:account) }
  let(:staff) { create(:user, account:, role: User::ADMIN_ROLE, email: 'legal@example.org', first_name: 'Lee') }
  let!(:frm108) do
    stevensed_form_template(account:, author: staff, external_id: 'FRM-108_v4.9', fields: StevensedIdentityHelper::FRM108_FIELDS)
  end
  let(:secret) { 'test-shared-secret' }

  around do |example|
    with_env(Stevensed::IdentityEvents::URL_ENV => 'https://idp.test/api/v1/agreements/events',
             Stevensed::IdentityEvents::SECRET_ENV => secret) { example.run }
  end

  before do
    create(:encrypted_config, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))
  end

  def signed_headers(method, path, body = '', key: secret, at: Time.current)
    ts = at.to_i.to_s
    sig = "v1=#{OpenSSL::HMAC.hexdigest('SHA256', key, "#{ts}.#{method}.#{path}.#{body}")}"

    { 'X-StevensED-Timestamp' => ts, 'X-StevensED-Signature' => sig, 'Content-Type' => 'application/json' }
  end

  describe 'GET /stevensed/identity/events' do
    it 'refuses an unsigned, wrongly signed or stale request' do
      get '/stevensed/identity/events?since=0'
      expect(response).to have_http_status(:unauthorized)

      get '/stevensed/identity/events?since=0',
          headers: signed_headers('GET', '/stevensed/identity/events?since=0', key: 'wrong')
      expect(response).to have_http_status(:unauthorized)

      get '/stevensed/identity/events?since=0',
          headers: signed_headers('GET', '/stevensed/identity/events?since=0', at: 10.minutes.ago)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'lists completions of the forms identity acts on, oldest first, as events' do
      old = stevensed_envelope(frm108, family_email: 'a@family.test', staff_email: staff.email,
                                       completed_at: 3.days.ago)
      recent = stevensed_envelope(frm108, family_email: 'b@family.test', staff_email: staff.email,
                                          completed_at: 1.hour.ago)
      path = "/stevensed/identity/events?since=#{2.days.ago.to_i}"

      get path, headers: signed_headers('GET', path)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body['events'].pluck('id')).to eq(["agr_#{recent.id}_completed"])
      expect(response.parsed_body['events'].first['type']).to eq('envelope.completed')
      expect(response.parsed_body['next_since']).to eq(recent.completed_at.to_i)
      expect(old).to be_persisted
    end
  end

  describe 'POST /stevensed/identity/envelopes' do
    let(:payload) do
      { request_id: 'req_0123456789', form_key: 'FRM-108', sent_by: staff.email, student_id: 'u_kid',
        household_id: 'h_family', guardian: { name: 'Pat Parent', email: 'Pat@Family.test' },
        student: { name: 'Sam Student' } }.to_json
    end

    it 'creates the envelope with the IDs on its metadata and the guardian prefilled, once per request_id' do
      expect do
        post '/stevensed/identity/envelopes', params: payload,
                                              headers: signed_headers('POST', '/stevensed/identity/envelopes', payload)
      end.to change(Submission, :count).by(1)

      expect(response).to have_http_status(:created)
      submission = Submission.find(response.parsed_body['envelope_id'])
      parent = submission.submitters.find_by(email: 'pat@family.test')
      staff_submitter = submission.submitters.find_by(email: staff.email)

      expect(submission.created_by_user).to eq(staff)
      expect(response.parsed_body).to include('form_key' => 'FRM-108', 'form_version' => '4.9', 'repeated' => false)
      expect(parent.metadata).to include('stevensed_student_id' => 'u_kid', 'stevensed_household_id' => 'h_family',
                                         'stevensed_request_id' => 'req_0123456789')
      expect(parent.preferences['default_values'] || parent.values)
        .to include(field_uuid(frm108, '1. Student legal name') => 'Sam Student',
                    field_uuid(frm108, '1. Parent/guardian full name') => 'Pat Parent')
      expect(staff_submitter.metadata['stevensed_student_id']).to eq('u_kid')
      expect(Stevensed::IdentityEvents.links(submission)['student_id']).to eq('u_kid')

      expect do
        post '/stevensed/identity/envelopes', params: payload,
                                              headers: signed_headers('POST', '/stevensed/identity/envelopes', payload)
      end.not_to change(Submission, :count)
      expect(response.parsed_body).to include('envelope_id' => submission.id, 'repeated' => true)
    end

    it 'uses the version in effect today, not one that starts later' do
      stevensed_form_template(account:, author: staff, external_id: 'FRM-108_v5.0', fields: StevensedIdentityHelper::FRM108_FIELDS,
                              effective: 1.month.from_now.to_date)

      post '/stevensed/identity/envelopes', params: payload,
                                            headers: signed_headers('POST', '/stevensed/identity/envelopes', payload)

      expect(response.parsed_body['form_version']).to eq('4.9')
    end

    it 'refuses a body changed after signing, and a form with no version in effect' do
      signed = signed_headers('POST', '/stevensed/identity/envelopes', payload)
      post '/stevensed/identity/envelopes', params: payload.sub('u_kid', 'u_other'), headers: signed
      expect(response).to have_http_status(:unauthorized)

      other = JSON.parse(payload).merge('form_key' => 'FRM-999').to_json
      post '/stevensed/identity/envelopes', params: other,
                                            headers: signed_headers('POST', '/stevensed/identity/envelopes', other)
      expect(response).to have_http_status(:not_found)
    end
  end
end
