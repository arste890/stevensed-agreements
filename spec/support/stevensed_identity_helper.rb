# frozen_string_literal: true

# StevensED: FRM-108 and FRM-101 templates shaped like the live ones (field names as on the forms), for the
# auth.stevensed.org event channel specs.
module StevensedIdentityHelper
  FRM108_FIELDS = [
    ['Parent', 'text', '1. Student legal name'],
    ['Parent', 'date', '1. Student date of birth'],
    ['Parent', 'text', '1. Parent/guardian full name'],
    ['Parent', 'text', '1. Parent/guardian email on file'],
    ['Parent', 'text', '1. Parent/guardian phone on file'],
    ['Parent', 'radio', '9. Your choice'],
    ['Parent', 'signature', 'Parent — Signature'],
    ['StevensED', 'date', '11. Parent consent verified by StevensED staff on (date)'],
    ['StevensED', 'text', '11. StevensED staff member'],
    ['StevensED', 'text', '11. Form version'],
    ['StevensED', 'radio', '11. StevensED use only']
  ].freeze

  FRM101_FIELDS = [
    ['Parent', 'text', '1. Applicant name'],
    ['Parent', 'date', '1. Applicant date of birth']
  ].freeze

  def stevensed_form_template(account:, author:, external_id:, fields:, roles: %w[Parent StevensED], effective: nil)
    template = create(:template, account:, author:, only_field_types: %w[text])
    submitters = roles.map { |name| { 'name' => name, 'uuid' => SecureRandom.uuid } }
    by_role = submitters.index_by { |s| s['name'] }
    attachment_uuid = template.schema.first['attachment_uuid']

    template.update!(
      external_id:, name: external_id.tr('_', ' '), submitters:,
      fields: fields.map do |role, type, name|
        { 'uuid' => SecureRandom.uuid, 'submitter_uuid' => by_role.fetch(role)['uuid'], 'name' => name,
          'type' => type, 'required' => false,
          'areas' => [{ 'x' => 0.1, 'y' => 0.1, 'w' => 0.2, 'h' => 0.02, 'page' => 0,
                        'attachment_uuid' => attachment_uuid }] }
      end,
      preferences: template.preferences.merge(
        Stevensed::PolicySync::PREFERENCE_KEY => { 'key' => external_id.split('_v').first,
                                                   'version' => external_id.split('_v').last,
                                                   'effective' => (effective || 1.month.ago.to_date).iso8601 }
      )
    )
    template
  end

  def with_env(values)
    saved = values.keys.index_with { |k| ENV.fetch(k, nil) }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved&.each { |k, v| ENV[k] = v }
  end

  def field_uuid(template, name)
    template.fields.find { |f| f['name'] == name }.fetch('uuid')
  end

  # A completed envelope. `values` maps field names to values; `metadata` goes on every submitter.
  def stevensed_envelope(template, family_email:, staff_email:, values: {}, metadata: {}, completed_at: Time.current)
    submission = create(:submission, template:, created_by_user: template.author, completed_at:)
    roles = template.submitters

    roles.map do |role|
      own = values.select do |name, _|
        template.fields.any? do |f|
          f['name'] == name && f['submitter_uuid'] == role['uuid']
        end
      end

      create(:submitter, submission:, account: template.account, uuid: role['uuid'],
                         email: role['name'] == 'StevensED' ? staff_email : family_email,
                         metadata:, completed_at:,
                         values: own.to_h { |name, value| [field_uuid(template, name), value] })
    end

    submission.reload
  end
end

RSpec.configure do |config|
  config.include StevensedIdentityHelper
end
