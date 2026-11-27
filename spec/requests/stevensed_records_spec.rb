# frozen_string_literal: true

describe 'Signed records and archived templates' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account:, role: User::ADMIN_ROLE) }
  let(:template) { create(:template, account:, author: admin, only_field_types: %w[text]) }
  let!(:record) do
    submission = create(:submission, template:, created_by_user: admin, completed_at: 1.day.ago)
    create(:submitter, submission:, account:, uuid: template.submitters.first['uuid'], email: 'family@example.org',
                       completed_at: 1.day.ago)
    submission
  end

  before { sign_in(admin) }

  it 'keeps a record active when its template is archived as a superseded version' do
    template.update!(archived_at: Time.current)

    get submissions_path
    expect(response.body).to include(%(id="submission_#{record.id}"), 'Signed on an earlier form version')

    get submissions_archived_index_path
    expect(response.body).not_to include(%(id="submission_#{record.id}"))
  end

  it 'archives a record only with a recorded reason, and lists it under Archived' do
    delete submission_path(record), params: { archive_reason: 'entered_in_error', archive_note: 'Wrong family' }

    expect(record.reload.archived_at).to be_present
    expect(record.submission_events.find_by!(event_type: 'stevensed_archived').data)
      .to include('reason' => 'entered_in_error', 'note' => 'Wrong family')

    get submissions_archived_index_path
    expect(response.body).to include(%(id="submission_#{record.id}"), 'Archived: Entered in error')

    get submissions_path
    expect(response.body).not_to include(%(id="submission_#{record.id}"))
  end
end
