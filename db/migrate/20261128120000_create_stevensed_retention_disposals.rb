# frozen_string_literal: true

# StevensED: the minimal record kept when a signed record is disposed of under the Records Retention Policy (INF-002).
# It holds what was disposed of and under which rule, never names, email addresses, dates of birth or form content.
class CreateStevensedRetentionDisposals < ActiveRecord::Migration[8.1]
  def change
    create_table :stevensed_retention_disposals do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.bigint :submission_id, null: false
      t.bigint :template_id
      t.string :document_id, null: false
      t.string :form_key, null: false
      t.string :form_version
      t.string :rule, null: false
      t.date :completed_on, null: false
      t.date :period_ended_on, null: false
      t.jsonb :pdf_sha256, null: false, default: []
      t.datetime :disposed_at, null: false
      t.timestamps
    end

    add_index :stevensed_retention_disposals, %i[account_id disposed_at]
    add_index :stevensed_retention_disposals, :submission_id, unique: true
  end
end
