# frozen_string_literal: true

RSpec.describe ProcessSubmitterCompletionJob do
  let(:account) { create(:account) }
  let(:staff) { create(:user, account:, role: User::ADMIN_ROLE, email: 'legal@example.org') }
  let(:frm108) do
    stevensed_form_template(account:, author: staff, external_id: 'FRM-108_v4.9', fields: StevensedIdentityHelper::FRM108_FIELDS)
  end

  before do
    create(:encrypted_config, key: EncryptedConfig::ESIGN_CERTS_KEY,
                              value: GenerateCertificate.call.transform_values(&:to_pem))
  end

  it 'queues the identity event once the last signer completes, and not before' do
    submission = stevensed_envelope(frm108, family_email: 'pat@family.test', staff_email: staff.email)
    parent, countersigner = submission.submitters.sort_by(&:id)
    countersigner.update!(completed_at: nil)
    submission.update!(completed_at: nil)

    with_env(Stevensed::IdentityEvents::URL_ENV => 'https://idp.test/x',
             Stevensed::IdentityEvents::SECRET_ENV => 's') do
      expect do
        described_class.new.perform('submitter_id' => parent.id)
      end.not_to change(StevensedIdentityEventJob.jobs, :size)

      countersigner.update!(completed_at: Time.current)
      Submissions.maybe_update_completed_at(submission.reload)

      expect { described_class.new.perform('submitter_id' => countersigner.id) }
        .to change(StevensedIdentityEventJob.jobs, :size).by(1)
    end
  end
end
