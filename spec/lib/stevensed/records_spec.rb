# frozen_string_literal: true

describe Stevensed::Records do
  let(:account) { create(:account) }
  let(:staff) { create(:user, account:, role: User::ADMIN_ROLE, email: 'legal@example.org') }

  def form_template(version)
    template = create(:template, account:, author: staff, only_field_types: %w[text])
    template.update!(external_id: "FRM-108_v#{version}", name: "FRM-108 v#{version}",
                     submitters: [{ 'name' => 'Parent', 'uuid' => SecureRandom.uuid },
                                  { 'name' => 'StevensED', 'uuid' => SecureRandom.uuid }])
    template
  end

  def signed(template, parent_email, completed_at: Time.current)
    submission = create(:submission, template:, created_by_user: staff, completed_at:)
    create(:submitter, submission:, account:, uuid: template.submitters.first['uuid'], email: parent_email,
                       name: 'Parent', completed_at:)
    create(:submitter, submission:, account:, uuid: template.submitters.second['uuid'], email: staff.email,
                       name: 'StevensED Admin', completed_at:)
    submission
  end

  let(:old_template) { form_template('4.6') }
  let(:new_template) { form_template('4.7') }

  describe '.supersede_earlier!' do
    it 'archives the same family\'s earlier version, links it and records an event' do
      earlier = signed(old_template, 'family@example.org', completed_at: 2.days.ago)
      other_family = signed(old_template, 'other@example.org', completed_at: 2.days.ago)
      newer = signed(new_template, 'Family@Example.org')

      expect(described_class.supersede_earlier!(newer)).to eq([earlier])

      earlier.reload

      expect(earlier.archived_at).to be_present
      expect(described_class.archive_info(earlier)).to include('kind' => 'superseded',
                                                               'superseded_by_submission_id' => newer.id)
      event = earlier.submission_events.find_by!(event_type: 'stevensed_superseded')
      expect(event.submitter.email).to eq('family@example.org')
      expect(described_class.event_text(event, 'Parent')).to include("envelope #{newer.id}", 'version 4.7')
      expect(other_family.reload.archived_at).to be_nil
      expect(newer.reload.archived_at).to be_nil
    end

    it 'never links records through a staff countersigner' do
      earlier = signed(old_template, 'family@example.org', completed_at: 2.days.ago)
      newer = signed(new_template, 'someone-else@example.org')

      expect(described_class.supersede_earlier!(newer)).to be_empty
      expect(earlier.reload.archived_at).to be_nil
    end

    it 'leaves a newer version alone when an older one is completed later' do
      newer = signed(new_template, 'family@example.org', completed_at: 2.days.ago)
      older_signed_later = signed(old_template, 'family@example.org')

      expect(described_class.supersede_earlier!(older_signed_later)).to be_empty
      expect(newer.reload.archived_at).to be_nil
    end
  end

  describe '.archive_by_staff! and .unarchive!' do
    it 'keeps the reason and the user with the record and logs both steps' do
      record = signed(old_template, 'family@example.org')

      described_class.archive_by_staff!(record, user: staff, reason: 'duplicate', note: 'Sent twice')

      expect(record.reload.archived_at).to be_present
      expect(described_class.archive_info(record)).to include('kind' => 'staff', 'reason' => 'duplicate',
                                                              'note' => 'Sent twice')
      event = record.submission_events.find_by!(event_type: 'stevensed_archived')
      expect(described_class.event_text(event, nil)).to include('Duplicate: Sent twice')

      described_class.unarchive!(record, user: staff)

      expect(record.reload.archived_at).to be_nil
      expect(described_class.archive_info(record)).to be_nil
      expect(record.submission_events.exists?(event_type: 'stevensed_unarchived')).to be(true)
    end
  end
end
