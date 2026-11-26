# frozen_string_literal: true

# StevensED: read-only access to records imported from the former DocuSeal cloud account
# (signed documents, combined PDFs and audit logs, verified against the audit log checksums).
class ImportedRecordsController < ApplicationController
  ROOT = Pathname.new(ENV.fetch('STEVENSED_IMPORTS_DIR', '/data/imported')).join('docuseal-cloud')

  before_action -> { authorize!(:manage, current_account) }

  def index
    @records = Dir.glob(ROOT.join('*', 'metadata.json')).filter_map do |path|
      JSON.parse(File.read(path)).merge('dir' => File.basename(File.dirname(path)))
    rescue JSON::ParserError
      nil
    end
    @records.sort_by! { |r| r['completed_at'].to_s }.reverse!
  end

  def show
    record_dir = Dir.glob(ROOT.join('*')).find { |d| File.basename(d) == params[:id].to_s }
    raise ActiveRecord::RecordNotFound unless record_dir

    allowed = JSON.parse(File.read(File.join(record_dir, 'metadata.json'))).fetch('files', {}).keys
    allowed |= %w[audit-log.pdf]
    name = allowed.find { |f| f == params[:file].to_s }
    raise ActiveRecord::RecordNotFound unless name

    send_file File.join(record_dir, name), type: 'application/pdf', disposition: 'inline'
  end
end
