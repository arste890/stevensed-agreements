# frozen_string_literal: true

module Stevensed
  # StevensED: keeps templates in step with the Policy Library (policies.stevensed.org).
  #
  # Reads the public forms manifest and packet list, and for every form and packet keeps:
  #   - the version in effect today (the highest version whose effective date has passed), and
  #   - each version that takes effect later (the highest version for each future effective date).
  # Missing versions are created as templates (PDF and field map, both checked against the published SHA-256).
  # Templates for superseded versions are archived; documents already sent are not affected. Existing templates
  # are never edited: a version is immutable, and a new version arrives as a new template.
  #
  # Run: Stevensed::PolicySync.call(apply: false) for a plan, apply: true to make the changes.
  module PolicySync
    BASE_URL = ENV.fetch('STEVENSED_POLICY_LIBRARY_URL', 'https://policies.stevensed.org')
    MANIFEST_PATH = 'forms/manifest.json'
    ENVELOPES_PATH = 'forms/docuseal/envelopes/envelopes.json'
    TIME_ZONE = 'America/Denver'
    USER_AGENT = 'StevensED-Agreements-PolicySync/1.0 (+https://agreements.stevensed.org)'
    PREFERENCE_KEY = 'stevensed_policy_sync'
    FORM_EXTERNAL_ID = /\A(?<key>FRM-\d{3}(?:-[A-Z0-9]+)?)_v(?<version>\d+(?:\.\d+)*)\z/
    LEGACY_PACKET_EXTERNAL_ID = /\Afirst-time-enrollment-(?:m|a|u13)-\d{4}-\d{2}-\d{2}\z/
    AUDIENCE_LABELS = { 'minor' => 'Minor Student', 'adult' => 'Adult Student', 'child' => 'Student Under 13' }.freeze

    Item = Struct.new(:external_id, :key, :version, :effective, :name, :folder, :pdf_path, :pdf_sha256,
                      :fields, :roles, keyword_init: true)

    module_function

    def call(apply: false, today: Time.current.in_time_zone(TIME_ZONE).to_date, http: nil)
      http ||= method(:fetch)
      account = Account.order(:id).first
      wanted = form_items(JSON.parse(http.call(MANIFEST_PATH)), today, http) +
               packet_items(JSON.parse(http.call(ENVELOPES_PATH)), today, http)

      existing = Template.where(account:).to_a
      by_external_id = existing.index_by(&:external_id)
      to_create = wanted.reject { |item| by_external_id[item.external_id] }
      to_archive = managed(existing).reject { |t| t.archived_at? || wanted.any? { |i| i.external_id == t.external_id } }

      if apply
        author = account.users.where(role: User::ADMIN_ROLE).order(:id).first
        to_create.each { |item| create_template(account, author, item, http) }
        to_archive.each { |template| template.update!(archived_at: Time.current) }
      end

      { kept: wanted.size - to_create.size, created: to_create.map(&:external_id),
        archived: to_archive.map { |t| [t.id, t.external_id, t.name] } }
    end

    def fetch(path)
      resp = Faraday.get("#{BASE_URL}/#{path}", nil, 'User-Agent' => USER_AGENT) { |req| req.options.timeout = 60 }
      raise "#{path}: HTTP #{resp.status}" unless resp.success?

      resp.body
    end

    # Only versions with a field map are considered (older numbering from before forms were renumbered has none).
    # The version in effect today is the highest version number whose effective date has passed. Later versions
    # are kept too: for each future effective date, the highest version number above the one in effect.
    def selected_versions(versions, today)
      list = versions.map { |number, v| [number, v, Date.parse(v['effective']), Gem::Version.new(number)] }
      in_effect = list.select { |_, _, date, _| date <= today }.max_by(&:last)
      pending = list.select { |_, _, date, ver| date > today && (in_effect.nil? || ver > in_effect.last) }
                    .group_by { |item| item[2] }.values.map { |items| items.max_by(&:last) }

      [in_effect, *pending].compact.map { |number, v, _, _| [number, v] }
    end

    def form_items(manifest, today, http)
      manifest.fetch('forms').flat_map do |key, form|
        mapped = form.fetch('versions').select { |_, v| v.dig('docuseal', 'file').to_s.end_with?('.json') }

        selected_versions(mapped, today).map do |number, version|
          map = JSON.parse(http.call(version.dig('docuseal', 'file')))
          effective = Date.parse(version['effective'])

          Item.new(external_id: "#{key}_v#{number}", key:, version: number, effective:,
                   name: form_name(form, number, effective, today), folder: folder_for(key),
                   pdf_path: version.fetch('file'), pdf_sha256: version.fetch('sha256'),
                   fields: map.fetch('fields'), roles: map['roles'])
        end
      end
    end

    def packet_items(envelopes, today, http)
      families = envelopes.group_by { |key, _| key.sub(/-from-\d{4}-\d{2}-\d{2}\z/, '') }

      families.flat_map do |family, list|
        versions = list.to_h { |key, env| [key, env.merge('effective' => env.fetch('onDate'))] }
        in_effect = versions.values.map { |e| Date.parse(e['effective']) }.select { |d| d <= today }.max

        versions.values.filter_map do |env|
          effective = Date.parse(env['effective'])
          next if in_effect && effective < in_effect

          map = JSON.parse(http.call(env.fetch('file').sub(/\.pdf\z/, '.json')))
          digest = env.fetch('sha256')

          Item.new(external_id: "#{family}@#{digest[0, 12]}", key: family, version: digest[0, 12], effective:,
                   name: dated(env.fetch('title'), effective, today), folder: 'StevensED Enrollment',
                   pdf_path: env.fetch('file'), pdf_sha256: digest, fields: map.fetch('fields'), roles: env['roles'])
        end
      end
    end

    def form_name(form, number, effective, today)
      audience = AUDIENCE_LABELS[form['audience']]
      dated("#{form.fetch('id')} #{form.fetch('title')}#{" (#{audience})" if audience} v#{number}", effective, today)
    end

    def dated(name, effective, today)
      effective > today ? "#{name} (from #{effective.strftime('%B %-d, %Y')})" : name
    end

    def folder_for(key)
      case key[/\AFRM-(\d)/, 1]
      when '5' then 'Faculty Forms'
      when '6' then 'Legal and Compliance Forms'
      else 'StevensED Enrollment'
      end
    end

    def managed(templates)
      templates.select do |t|
        t.preferences.to_h.key?(PREFERENCE_KEY) ||
          t.external_id.to_s.match?(FORM_EXTERNAL_ID) || t.external_id.to_s.match?(LEGACY_PACKET_EXTERNAL_ID)
      end
    end

    def create_template(account, author, item, http)
      pdf = http.call(item.pdf_path).b
      actual = Digest::SHA256.hexdigest(pdf)
      raise "#{item.pdf_path}: SHA-256 #{actual} does not match #{item.pdf_sha256}" if actual != item.pdf_sha256

      ApplicationRecord.transaction do
        folder = TemplateFolder.find_or_create_by!(account:, name: item.folder) { |f| f.author = author }
        roles = (item.roles.presence || item.fields.pluck('role')).map { |r| r.is_a?(Hash) ? r['name'] : r }.uniq
        submitters = roles.map { |name| { 'name' => name, 'uuid' => SecureRandom.uuid } }

        template = Template.create!(account:, author:, folder:, name: item.name, external_id: item.external_id,
                                    source: 'native', shared_link: false, submitters:, fields: [], schema: [],
                                    preferences: { PREFERENCE_KEY => { 'key' => item.key, 'version' => item.version,
                                                                       'effective' => item.effective.iso8601,
                                                                       'pdf' => item.pdf_path,
                                                                       'sha256' => item.pdf_sha256 } })

        documents, = Templates::CreateAttachments.call(template, { files: [uploaded_file(pdf, item.pdf_path)] })
        document = documents.first

        template.update!(schema: [{ 'attachment_uuid' => document.uuid, 'name' => item.name }],
                         fields: build_fields(item.fields, submitters, document.uuid, page_sizes(pdf)))
        template
      end
    end

    def uploaded_file(data, path)
      tempfile = Tempfile.new(['policy-sync', '.pdf'])
      tempfile.binmode
      tempfile.write(data)
      tempfile.rewind

      ActionDispatch::Http::UploadedFile.new(tempfile:, filename: File.basename(path), type: 'application/pdf')
    end

    def page_sizes(pdf)
      HexaPDF::Document.new(io: StringIO.new(pdf)).pages.map do |page|
        box = page.box(:media)
        [box.width, box.height]
      end
    end

    def build_fields(fields, submitters, attachment_uuid, sizes)
      role_uuids = submitters.to_h { |s| [s['name'], s['uuid']] }

      fields.map do |f|
        field = { 'uuid' => SecureRandom.uuid, 'name' => f.fetch('name'), 'type' => f.fetch('type'),
                  'required' => f['required'] == true, 'submitter_uuid' => role_uuids.fetch(f.fetch('role')) }
        field['readonly'] = true if f['readonly']
        field['default_value'] = f['default_value'] if f.key?('default_value')
        field['preferences'] = f['preferences'] if f['preferences'].present?
        field['description'] = f['description'] if f['description'].present?
        field['options'] = f['options'].map { |o| option(o) } if f['options'].present?
        field['areas'] = f.fetch('areas').map { |a| area(a, attachment_uuid, sizes) }
        field
      end
    end

    def option(src)
      { 'uuid' => SecureRandom.uuid, 'value' => src.is_a?(Hash) ? src['value'] : src }
    end

    # Policy Library field maps number pages from 1 (as the DocuSeal API does); templates count from 0.
    def area(src, attachment_uuid, sizes)
      page = src.fetch('page').to_i - 1
      raise "Field on page #{page + 1} of a #{sizes.size}-page PDF" if page.negative? || page >= sizes.size

      width, height = sizes.fetch(page)

      { 'attachment_uuid' => attachment_uuid, 'page' => page,
        'x' => src.fetch('x').to_f / width, 'y' => src.fetch('y').to_f / height,
        'w' => src.fetch('w').to_f / width, 'h' => src.fetch('h').to_f / height }
    end
  end
end
