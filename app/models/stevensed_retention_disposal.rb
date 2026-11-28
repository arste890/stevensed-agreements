# frozen_string_literal: true

# StevensED: the minimal record of a signed record disposed of under the Records Retention Policy (INF-002):
# which record (Document ID, form, version, PDF fingerprints), when it was completed and disposed of, and under
# which rule. It holds no names, email addresses, dates of birth or form content (Stevensed::Retention).
class StevensedRetentionDisposal < ApplicationRecord
  belongs_to :account

  validates :submission_id, :document_id, :form_key, :rule, :completed_on, :period_ended_on, :disposed_at,
            presence: true
end
