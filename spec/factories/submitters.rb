# frozen_string_literal: true

FactoryBot.define do
  factory :submitter do
    submission
    email { Faker::Internet.email }
    name { Faker::Name.name }

    transient do
      # StevensED: signers accept the electronic records consent before signing; pass false to see the consent step.
      esign_consent { true }
    end

    before(:create) do |submitter, _|
      submitter.account_id = submitter.submission.account_id
    end

    after(:create) do |submitter, evaluator|
      if evaluator.esign_consent
        SubmissionEvent.create!(submitter:, event_type: :accept_esign_consent, data: { ip: '127.0.0.1' })
      end
    end
  end
end
