# frozen_string_literal: true

# StevensED: parses a CSV or XLSX list for bulk send. Returns [[sheet_name, rows], ...] for import_list.vue.
class UploadSpreadsheetsController < ApplicationController
  MAX_SIZE = 10.megabytes
  MAX_ROWS = 2_000
  BOM = [0xFEFF].pack('U')

  def create
    authorize!(:manage, :bulk_send)

    file = params.require(:file)

    return render json: { error: I18n.t('stevensed.spreadsheet_too_large') } if file.size > MAX_SIZE

    render json: parse(file)
  rescue CSV::MalformedCSVError, Zip::Error, ArgumentError, IOError => e
    Rails.logger.warn("Spreadsheet upload failed: #{e.class}")

    render json: { error: I18n.t('stevensed.spreadsheet_invalid') }
  end

  private

  def parse(file)
    case File.extname(file.original_filename.to_s).downcase
    when '.csv', '.txt'
      text = file.read.force_encoding('UTF-8').delete_prefix(BOM)
      [['CSV', CSV.parse(text).first(MAX_ROWS + 1).map { |row| row.map { |v| v.to_s.strip } }]]
    when '.xlsx'
      require 'roo'

      book = Roo::Excelx.new(file.tempfile.path, file_warning: :ignore)

      book.sheets.map do |name|
        [name, sheet_rows(book.sheet(name))]
      end
    else
      raise ArgumentError, 'unsupported'
    end
  end

  def sheet_rows(sheet)
    return [] if sheet.last_row.to_i.zero?

    last = [sheet.last_row, sheet.first_row + MAX_ROWS].min

    (sheet.first_row..last).map { |i| sheet.row(i).map { |v| cell_text(v) } }
  end

  def cell_text(value)
    case value
    when Date, Time, DateTime then value.to_date.iso8601
    when Float then value == value.to_i ? value.to_i.to_s : value.to_s
    else value.to_s.strip
    end
  end
end
