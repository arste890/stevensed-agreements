# frozen_string_literal: true

# StevensED: read-only access to records imported from the former DocuSeal cloud account
# (signed documents, combined PDFs and audit logs, verified against the audit log checksums).
class ImportedRecordsController < ApplicationController
  ROOT = Pathname.new(ENV.fetch('STEVENSED_IMPORTS_DIR', '/data/imported')).join('docuseal-cloud')

  AUDIT_LOG_FILE = 'audit-log.pdf'
  COMBINED_FILE = 'combined.pdf'
  STEVENSED_ROLE = /\Astevensed\b/i

  before_action -> { authorize!(:manage, current_account) }

  helper_method :record_signers, :record_downloads, :record_completed_on

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
    allowed |= [AUDIT_LOG_FILE]
    name = allowed.find { |f| f == params[:file].to_s }
    raise ActiveRecord::RecordNotFound unless name

    send_file File.join(record_dir, name), type: 'application/pdf', disposition: 'inline'
  end

  private

  # Signers in a fixed order: the other parties in the order the envelope listed them, StevensED last.
  def record_signers(record)
    record['submitters'].to_a.each_with_index
                        .sort_by { |s, i| [s['role'].to_s.match?(STEVENSED_ROLE) ? 1 : 0, i] }
                        .map(&:first)
  end

  # Downloads in one order: each signed document, then the audit log, then the combined PDF.
  # Only files listed in the record's metadata are offered (the same list #show serves).
  def record_downloads(record)
    files = record['files'].to_h.keys
    signed = files - [AUDIT_LOG_FILE, COMBINED_FILE]

    downloads = signed.each_with_index.map do |file, index|
      label = if signed.size > 1
                I18n.t('stevensed.imported_records_signed_document_n', n: index + 1)
              else
                I18n.t('stevensed.imported_records_signed_document')
              end

      { file:, label: }
    end

    { AUDIT_LOG_FILE => 'audit_log', COMBINED_FILE => 'combined' }.each do |file, key|
      downloads << { file:, label: I18n.t("stevensed.imported_records_#{key}") } if files.include?(file)
    end

    downloads
  end

  def record_completed_on(record)
    Time.zone.parse(record['completed_at'].to_s)&.to_date
  rescue ArgumentError
    nil
  end
end
