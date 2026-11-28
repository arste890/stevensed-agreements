# frozen_string_literal: true

describe 'Litigation hold on a record' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account:, role: User::ADMIN_ROLE) }
  let(:template) { create(:template, account:, author: admin, only_field_types: %w[text]) }
  let(:submission) { create(:submission, :with_submitters, template:, created_by_user: admin) }

  it 'lets an admin place and release a hold, and logs both' do
    sign_in(admin)

    post submission_litigation_hold_path(submission), params: { hold_note: 'Matter 2027-01' }

    expect(response).to redirect_to(submission_path(submission))
    expect(Stevensed::Retention.hold(submission.reload)).to include('note' => 'Matter 2027-01')

    delete submission_litigation_hold_path(submission)

    expect(Stevensed::Retention.held?(submission.reload)).to be(false)
    expect(submission.submission_events.pluck(:event_type)).to include('stevensed_hold_placed',
                                                                       'stevensed_hold_released')
  end

  it 'refuses a user who is not an admin' do
    editor = create(:user, account:, role: 'editor')
    sign_in(editor)

    post submission_litigation_hold_path(submission), params: { hold_note: 'x' }

    expect(Stevensed::Retention.held?(submission.reload)).to be(false)
  end
end
