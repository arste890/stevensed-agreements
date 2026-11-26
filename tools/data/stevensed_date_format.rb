# frozen_string_literal: true

# StevensED: store the StevensED date style (D MMMM YYYY, e.g. 26 November 2026) on date fields of every template and
# of every envelope that is not yet complete, so the template builder shows what is rendered. Date fields whose format
# has a time or no day keep their own pattern. Completed envelopes are left as they are (their signed PDFs are final;
# the app already displays their dates in the StevensED style). Values (ISO dates) are not changed.
# Usage (in the app container): DRY_RUN=1 bin/rails runner tools/data/stevensed_date_format.rb, then without DRY_RUN.

DRY = ENV['DRY_RUN'] == '1'

def restyle(fields)
  changed = 0
  fields = fields.deep_dup
  fields.each do |field|
    next unless field['type'] == 'date'

    format = TimeUtils.stevensed_format(field.dig('preferences', 'format'))
    next if field.dig('preferences', 'format') == format

    field['preferences'] = (field['preferences'] || {}).merge('format' => format)
    changed += 1
  end
  [fields, changed]
end

counts = { templates: 0, template_fields: 0, submissions: 0, submission_fields: 0 }

ActiveRecord::Base.transaction do
  Template.find_each do |template|
    fields, changed = restyle(template.fields)
    next if changed.zero?

    template.update_columns(fields:)
    counts[:templates] += 1
    counts[:template_fields] += changed
  end

  Submission.where(completed_at: nil).where.not(template_fields: nil).find_each do |submission|
    fields, changed = restyle(submission.template_fields)
    next if changed.zero?

    submission.update_columns(template_fields: fields)
    counts[:submissions] += 1
    counts[:submission_fields] += changed
  end

  puts counts.inspect
  raise ActiveRecord::Rollback if DRY
end
puts DRY ? 'DRY RUN: rolled back' : 'COMMITTED'
