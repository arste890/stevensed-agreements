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
    dir = ROOT.join(params[:id].to_s.gsub(/\D/, ''))
    file = dir.join(File.basename(params[:file].to_s))

    raise ActiveRecord::RecordNotFound unless file.extname == '.pdf' && file.file? && file.dirname == dir

    send_file file, type: 'application/pdf', disposition: 'inline'
  end
end
