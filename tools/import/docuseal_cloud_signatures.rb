# frozen_string_literal: true

# StevensED: add the drawn signature images to submissions imported by docuseal_cloud_import.rb.
# Usage (in the app container): DRY_RUN=1 bin/rails runner tools/import/docuseal_cloud_signatures.rb
# Input: /data/imported/docuseal-cloud/signatures/mapping.json and the PNG files it lists
#        (downloaded from the DocuSeal cloud API; sha256 recorded per file).
# Idempotent: a field that already holds a value is left unchanged.

ROOT = Pathname.new('/data/imported/docuseal-cloud/signatures')
MAPPING = JSON.parse(ROOT.join('mapping.json').read)
DRY = ENV['DRY_RUN'] == '1'
KEY = 'imported_from_docuseal_cloud_id'

account = Account.order(:id).first
report = []

ActiveRecord::Base.transaction do
  MAPPING.each do |m|
    data = ROOT.join(m['file']).binread
    raise "checksum mismatch: #{m['file']}" if Digest::SHA256.hexdigest(data) != m['sha256']

    submission = Submission.where(account:).find { |s| s.preferences.to_h[KEY].to_s == m['cloud_submission_id'].to_s }
    raise "submission not imported: #{m['cloud_submission_id']}" unless submission

    submitter = submission.submitters.find_by!(uuid: m['submitter_uuid'])
    field = submission.template_fields.find { |f| f['name'] == m['field'] && f['submitter_uuid'] == submitter.uuid }
    raise "field not found: #{m['field']}" unless field

    if submitter.values[field['uuid']].present?
      report << [submission.id, m['field'], 'exists']
      next
    end

    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(data), filename: "#{field['type']}.png",
                                                  content_type: 'image/png')
    attachment = ActiveStorage::Attachment.create!(blob:, name: 'attachments', record: submitter)
    submitter.update_columns(values: submitter.values.merge(field['uuid'] => attachment.uuid))
    report << [submission.id, m['field'], 'added']
  end

  pp report
  raise ActiveRecord::Rollback if DRY
end
