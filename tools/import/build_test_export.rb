# frozen_string_literal: true

# rubocop:disable Metrics/BlockLength, Layout/LineLength -- one-off rehearsal tool

# StevensED: build a synthetic test export in the DocuSeal cloud export layout, for rehearsing the import scripts
# without real records. Every name, address and document here is invented.
# Usage (rehearsal container): IMPORT_ROOT=/data/rehearsal-export bin/rails runner tools/import/build_test_export.rb
# Layout: export/export.json, export/docs/<uuid>.pdf, <envelope id>/{metadata.json, signed PDF, combined.pdf,
#         audit-log.pdf}, signatures/{mapping.json, *.png}.

require_relative 'import_guard'

root = ImportGuard.import_root
abort("Refusing to write a test export into the live export folder (#{root}).") if
  root.expand_path.to_s == ImportGuard::LIVE_IMPORT_ROOT
abort("#{root} is not empty; remove it or choose another IMPORT_ROOT.") if root.exist? && root.children.any?

def write_pdf(path, lines)
  doc = HexaPDF::Document.new
  canvas = doc.pages.add([0, 0, 612, 792]).canvas
  canvas.font('Helvetica', size: 12)
  lines.each_with_index { |line, i| canvas.text(line, at: [72, 720 - (i * 18)]) }
  FileUtils.mkdir_p(path.dirname)
  doc.write(path.to_s)
end

def sha256(path) = Digest::SHA256.hexdigest(path.binread)

def area(doc_uuid, top) = { 'attachment_uuid' => doc_uuid, 'page' => 0, 'x' => 0.12, 'y' => top, 'w' => 0.35, 'h' => 0.04 }

def field(name, type, submitter_uuid, doc_uuid, top)
  { 'uuid' => SecureRandom.uuid, 'name' => name, 'type' => type, 'required' => true,
    'submitter_uuid' => submitter_uuid, 'areas' => [area(doc_uuid, top)] }
end

roles = { parent: SecureRandom.uuid, office: SecureRandom.uuid, signer: SecureRandom.uuid }
docs = { consent: SecureRandom.uuid, ack: SecureRandom.uuid }

templates = [
  { 'id' => 900_001, 'name' => 'Rehearsal Consent Form (test data)', 'folder_name' => 'Rehearsal',
    'external_id' => 'REHEARSAL-1', 'preferences' => {}, 'variables_schema' => nil,
    'submitters' => [{ 'name' => 'Parent', 'uuid' => roles[:parent] }, { 'name' => 'StevensED', 'uuid' => roles[:office] }],
    'documents' => [{ 'uuid' => docs[:consent], 'filename' => 'rehearsal-consent.pdf' }],
    'schema' => [{ 'attachment_uuid' => docs[:consent], 'name' => 'rehearsal-consent' }],
    'fields' => [field('Parent name', 'text', roles[:parent], docs[:consent], 0.30),
                 field('Parent signature', 'signature', roles[:parent], docs[:consent], 0.40),
                 field('Parent date', 'date', roles[:parent], docs[:consent], 0.50),
                 field('Staff name', 'text', roles[:office], docs[:consent], 0.60)] },
  { 'id' => 900_002, 'name' => 'Rehearsal Acknowledgment (test data)', 'folder_name' => 'Rehearsal',
    'external_id' => 'REHEARSAL-2', 'preferences' => {}, 'variables_schema' => nil,
    'submitters' => [{ 'name' => 'Signer', 'uuid' => roles[:signer] }],
    'documents' => [{ 'uuid' => docs[:ack], 'filename' => 'rehearsal-acknowledgment.pdf' }],
    'schema' => [{ 'attachment_uuid' => docs[:ack], 'name' => 'rehearsal-acknowledgment' }],
    'fields' => [field('Signer name', 'text', roles[:signer], docs[:ack], 0.30),
                 field('Signer signature', 'signature', roles[:signer], docs[:ack], 0.40)] }
]

write_pdf(root.join('export/docs', "#{docs[:consent]}.pdf"), ['Rehearsal Consent Form', 'Synthetic test document.'])
write_pdf(root.join('export/docs', "#{docs[:ack]}.pdf"), ['Rehearsal Acknowledgment', 'Synthetic test document.'])

completed = Time.utc(2026, 11, 20, 18)
people = [
  { id: 990_001, template: templates[0], signers: [
    [roles[:parent], 'Parent', 'pat.example@example.org', 'Pat Example', [['Parent name', 'Pat Example'], ['Parent date', '2026-11-20']]],
    [roles[:office], 'StevensED', 'records.example@example.org', 'Office Example', [['Staff name', 'Office Example']]]
  ] },
  { id: 990_002, template: templates[1], signers: [
    [roles[:signer], 'Signer', 'sam.example@example.org', 'Sam Example', [['Signer name', 'Sam Example']]]
  ] }
]

EVENT_TIMES = [%w[view_form opened_at], %w[complete_form completed_at]].freeze

mapping = []
submissions = people.each_with_index.map do |sub, si|
  dir = root.join(sub[:id].to_s)
  signed = "#{sub[:template]['external_id']}-signed.pdf"
  lines = [sub[:template]['name'], 'Completed rehearsal record (synthetic).']
  write_pdf(dir.join(signed), lines)
  write_pdf(dir.join('combined.pdf'), lines)
  write_pdf(dir.join('audit-log.pdf'), ['Audit log (synthetic)', "Envelope #{sub[:id]}"])
  files = [signed, 'combined.pdf', 'audit-log.pdf'].index_with { |f| sha256(dir.join(f)) }
  File.write(dir.join('metadata.json'), JSON.pretty_generate('id' => sub[:id], 'files' => files))

  submitters = sub[:signers].each_with_index.map do |(uuid, role, email, name, values), i|
    sig_field = sub[:template]['fields'].find { |f| f['type'] == 'signature' && f['submitter_uuid'] == uuid }
    if sig_field
      png = "#{sub[:id]}_#{i}.png"
      FileUtils.mkdir_p(root.join('signatures'))
      Vips::Image.text(name, dpi: 200).write_to_file(root.join('signatures', png).to_s)
      mapping << { 'cloud_submission_id' => sub[:id], 'submitter_uuid' => uuid, 'role' => role,
                   'field' => sig_field['name'], 'file' => png, 'content_type' => 'image/png',
                   'sha256' => sha256(root.join('signatures', png)) }
      values += [[sig_field['name'], '[image omitted; see signed PDF]']]
    end

    { 'id' => (sub[:id] * 10) + i, 'uuid' => uuid, 'role' => role, 'email' => email, 'name' => name,
      'phone' => nil, 'external_id' => nil, 'metadata' => {}, 'preferences' => {},
      'values' => values.map { |f, v| { 'field' => f, 'value' => v } },
      'created_at' => (completed - 3.days).iso8601, 'sent_at' => (completed - 3.days).iso8601,
      'opened_at' => (completed - 1.day).iso8601, 'completed_at' => (completed + (si * 3600) + i).iso8601,
      'declined_at' => nil }
  end

  events = submitters.flat_map do |s|
    EVENT_TIMES.map do |type, at|
      { 'id' => (s['id'] * 10) + (type == 'view_form' ? 1 : 2), 'event_type' => type,
        'event_timestamp' => s[at], 'submitter_id' => s['id'], 'data' => {} }
    end
  end

  { 'id' => sub[:id], 'name' => nil, 'submitters_order' => 'preserved', 'variables' => {},
    'created_at' => (completed - 3.days).iso8601, 'completed_at' => submitters.pluck('completed_at').max,
    'template' => { 'id' => sub[:template]['id'], 'name' => sub[:template]['name'] },
    'submitters' => submitters, 'submission_events' => events }
end

File.write(root.join('export/export.json'), JSON.pretty_generate('templates' => templates, 'submissions' => submissions))
File.write(root.join('signatures/mapping.json'), JSON.pretty_generate(mapping))
puts "Test export written to #{root}: #{templates.size} templates, #{submissions.size} submissions, " \
     "#{mapping.size} signatures."
# rubocop:enable Metrics/BlockLength, Layout/LineLength
