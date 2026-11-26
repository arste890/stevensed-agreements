# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength, Layout/LineLength -- one-off migration script

# StevensED: import templates and completed submissions exported from the former DocuSeal cloud account.
# Usage (in the app container), rehearsal first:
#   IMPORT_TARGET=rehearsal DRY_RUN=1 bin/rails runner tools/import/docuseal_cloud_import.rb
#   IMPORT_TARGET=live bin/rails runner tools/import/docuseal_cloud_import.rb
# Input: $IMPORT_ROOT/export/export.json (default /data/imported/docuseal-cloud) and docs/<document uuid>.pdf,
#        signed files in $IMPORT_ROOT/<envelope id>/ (verified against audit logs).
# Idempotent: records carry preferences['imported_from_docuseal_cloud_id'] and are skipped if present.

require_relative 'import_guard'

ROOT = ImportGuard.import_root
EXPORT = JSON.parse(ROOT.join('export/export.json').read)
DRY = ENV['DRY_RUN'] == '1'
ImportGuard.check!(dry_run: DRY)
KEY = 'imported_from_docuseal_cloud_id'

account = Account.order(:id).first
author = account.users.where(role: User::ADMIN_ROLE).order(:id).first
report = { templates: [], submissions: [] }

def upload(path, name, type = 'application/pdf')
  ActionDispatch::Http::UploadedFile.new(tempfile: File.open(path, 'rb'), filename: name, type:)
end

def remap_uuids(obj, map)
  case obj
  when Hash then obj.transform_values { |v| remap_uuids(v, map) }
  when Array then obj.map { |v| remap_uuids(v, map) }
  when String then map.fetch(obj, obj)
  else obj
  end
end

def attach(record, name, path, filename)
  data = File.binread(path)
  blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(data), filename:, content_type: 'application/pdf')
  ActiveStorage::Attachment.create!(blob:, name:, record:,
                                    metadata: { analyzed: true, sha256: Base64.urlsafe_encode64(Digest::SHA256.digest(data)) })
end

ImportGuard.with_upload_cleanup(dry_run: DRY) do
  ActiveRecord::Base.transaction do
    templates = {}

    EXPORT['templates'].each do |src|
      existing = Template.where(account:).find { |t| t.preferences.to_h[KEY].to_s == src['id'].to_s }
      if existing
        templates[src['id']] = existing
        report[:templates] << [src['name'], 'exists']
        next
      end

      folder = TemplateFolder.find_or_create_by!(account:, name: src['folder_name'].presence || TemplateFolder::DEFAULT_NAME) do |f|
        f.author = author
      end

      template = Template.create!(account:, author:, folder:, name: src['name'], external_id: src['external_id'],
                                  fields: [], submitters: src['submitters'], schema: [], source: 'native',
                                  preferences: src['preferences'].to_h.merge(KEY => src['id']), shared_link: false,
                                  variables_schema: src['variables_schema'].presence)

      uuid_map = {}
      src['documents'].each do |doc|
        path = ROOT.join('export/docs', "#{doc['uuid']}.pdf")
        created, = Templates::CreateAttachments.call(template, { files: [upload(path, doc['filename'])] })
        uuid_map[doc['uuid']] = created.first.uuid
      end

      template.update!(fields: remap_uuids(src['fields'], uuid_map), schema: remap_uuids(src['schema'], uuid_map))
      templates[src['id']] = template
      report[:templates] << [src['name'], "created (#{template.fields.size} fields, #{template.documents.count} documents)"]
    end

    EXPORT['submissions'].each do |src|
      if Submission.where(account:).any? { |s| s.preferences.to_h[KEY].to_s == src['id'].to_s }
        report[:submissions] << [src['id'], 'exists']
        next
      end

      template = templates.fetch(src.dig('template', 'id'))
      field_ids = template.fields.to_h { |f| [f['name'], f['uuid']] }

      submission = Submission.create!(account:, template:, created_by_user: author, source: 'invite',
                                      template_fields: template.fields, template_schema: template.schema,
                                      template_submitters: template.submitters,
                                      submitters_order: src['submitters_order'] || 'preserved', name: src['name'],
                                      variables: src['variables'].presence || {}, created_at: src['created_at'],
                                      completed_at: src['completed_at'], preferences: { KEY => src['id'] })

      cloud_to_local = {}
      src['submitters'].each do |sm|
        values = (sm['values'] || []).each_with_object({}) do |v, acc|
          uuid = field_ids[v['field']]
          acc[uuid] = v['value'] if uuid && !v['value'].to_s.start_with?('[image omitted')
        end

        submitter = Submitter.create!(submission:, account:, uuid: sm['uuid'], email: sm['email'], name: sm['name'],
                                      phone: sm['phone'], external_id: sm['external_id'], values:,
                                      sent_at: sm['sent_at'], opened_at: sm['opened_at'], completed_at: sm['completed_at'],
                                      declined_at: sm['declined_at'], created_at: sm['created_at'],
                                      metadata: sm['metadata'].to_h.merge(KEY => sm['id']), preferences: sm['preferences'].to_h)
        cloud_to_local[sm['id']] = submitter
      end

      dir = ROOT.join(src['id'].to_s)
      meta = JSON.parse(dir.join('metadata.json').read)
      last = cloud_to_local.values.select(&:completed_at).max_by(&:completed_at)
      meta['files'].each_key do |file|
        next if %w[combined.pdf audit-log.pdf].include?(file)

        attach(last, 'documents', dir.join(file), file)
      end
      attach(submission, 'audit_trail', dir.join('audit-log.pdf'), 'audit-log.pdf')
      attach(submission, 'combined_document', dir.join('combined.pdf'), 'combined.pdf')

      (src['submission_events'] || []).each do |ev|
        next unless SubmissionEvent.event_types.key?(ev['event_type'])

        SubmissionEvent.create!(submission:, account:, submitter: cloud_to_local[ev['submitter_id']],
                                event_type: ev['event_type'], event_timestamp: ev['event_timestamp'] || ev['created_at'],
                                data: (ev['data'] || {}).merge(KEY => ev['id']))
      end

      report[:submissions] << [src['id'], "#{template.name[0, 50]}: #{cloud_to_local.size} signers, " \
                                          "#{last.documents.count} documents, #{submission.submission_events.count} events"]
    end

    report[:templates].each { |n, s| puts "TEMPLATE #{n[0, 70]}: #{s}" }
    report[:submissions].each { |n, s| puts "SUBMISSION #{n}: #{s}" }
    puts DRY ? 'DRY RUN: rolled back' : 'COMMITTED'
    raise ActiveRecord::Rollback if DRY
  end
end
# rubocop:enable Metrics/BlockLength, Layout/LineLength
