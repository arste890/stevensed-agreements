# frozen_string_literal: true

# StevensED: delivers one signed event to auth.stevensed.org (Stevensed::IdentityEvents). A failed delivery raises, so
# Sidekiq retries it with exponential back-off (about three weeks across 20 attempts); identity's daily reconcile
# covers completions in the meantime. A 4xx other than 408 and 429 is a permanent refusal and is not retried.
class StevensedIdentityEventJob
  include Sidekiq::Job

  sidekiq_options queue: :webhooks, retry: 20

  DeliveryFailed = Class.new(StandardError)
  TIMEOUT = 15

  def perform(params = {})
    return unless Stevensed::IdentityEvents.configured?

    submission = Submission.find_by(id: params['submission_id'])

    return unless submission

    submitter = submission.submitters.find_by(id: params['submitter_id']) if params['submitter_id']
    event = Stevensed::IdentityEvents.build(params['type'], submission, event_id: params['event_id'], submitter:)
    body = event.to_json

    response = Faraday.post(Stevensed::IdentityEvents.url) do |req|
      req.headers.merge!(Stevensed::IdentityEvents.headers_for(body, event_id: event['id']))
      req.body = body
      req.options.timeout = TIMEOUT
      req.options.open_timeout = TIMEOUT
    end

    return if response.status.between?(200, 299)

    if response.status.between?(400, 499) && [408, 429].exclude?(response.status)
      Rails.logger.warn("StevensED identity event #{event['id']} refused: HTTP #{response.status}")

      return
    end

    raise DeliveryFailed, "HTTP #{response.status}"
  rescue Faraday::Error => e
    raise DeliveryFailed, e.class.name
  end
end
