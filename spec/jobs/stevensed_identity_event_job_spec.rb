# frozen_string_literal: true

RSpec.describe StevensedIdentityEventJob do
  let(:account) { create(:account) }
  let(:staff) { create(:user, account:, role: User::ADMIN_ROLE, email: 'legal@example.org') }
  let(:frm108) do
    stevensed_form_template(account:, author: staff, external_id: 'FRM-108_v4.9', fields: StevensedIdentityHelper::FRM108_FIELDS)
  end
  let(:submission) { stevensed_envelope(frm108, family_email: 'pat@family.test', staff_email: staff.email) }
  let(:url) { 'https://idp.test/api/v1/agreements/events' }
  let(:args) do
    { 'type' => 'envelope.completed', 'submission_id' => submission.id, 'event_id' => "agr_#{submission.id}_completed" }
  end

  around do |example|
    with_env(Stevensed::IdentityEvents::URL_ENV => url,
             Stevensed::IdentityEvents::SECRET_ENV => 'test-shared-secret') do
      freeze_time { example.run }
    end
  end

  it 'posts the event signed over "<timestamp>.<body>"' do
    stub_request(:post, url).to_return(status: 200)

    described_class.new.perform(args)

    expect(WebMock).to(have_requested(:post, url).with do |req|
      ts = req.headers['X-Stevensed-Timestamp']
      body = JSON.parse(req.body)

      req.headers['X-Stevensed-Signature'] ==
        "v1=#{OpenSSL::HMAC.hexdigest('SHA256', 'test-shared-secret', "#{ts}.#{req.body}")}" &&
        ts == Time.current.to_i.to_s && req.headers['X-Stevensed-Event-Id'] == args['event_id'] &&
        body['id'] == args['event_id'] && body['envelope']['id'] == submission.id
    end)
  end

  it 'raises on a server error so Sidekiq retries with back-off' do
    stub_request(:post, url).to_return(status: 503)

    expect { described_class.new.perform(args) }.to raise_error(described_class::DeliveryFailed)
  end

  it 'raises on a timeout' do
    stub_request(:post, url).to_timeout

    expect { described_class.new.perform(args) }.to raise_error(described_class::DeliveryFailed)
  end

  it 'does not retry a permanent refusal' do
    stub_request(:post, url).to_return(status: 401)

    expect { described_class.new.perform(args) }.not_to raise_error
  end

  it 'retries a rate limit' do
    stub_request(:post, url).to_return(status: 429)

    expect { described_class.new.perform(args) }.to raise_error(described_class::DeliveryFailed)
  end
end
