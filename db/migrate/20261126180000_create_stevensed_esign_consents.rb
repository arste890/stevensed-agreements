# frozen_string_literal: true

# StevensED: register of electronic records and signature consents (FRM-102, FRM-505, FRM-601) on file per signer.
class CreateStevensedEsignConsents < ActiveRecord::Migration[8.1]
  def change
    create_table :stevensed_esign_consents do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.string :email, null: false
      t.string :kind, null: false
      t.string :form_key, null: false
      t.string :form_version
      t.string :legal_name, null: false
      t.string :source, null: false
      t.references :submission, foreign_key: true, index: false
      t.references :submitter, foreign_key: true, index: false
      t.datetime :signed_at, null: false
      t.datetime :withdrawn_at
      t.references :withdrawn_by_user, foreign_key: { to_table: :users }, index: false
      t.text :note
      t.timestamps

      t.index %i[account_id email]
      t.index :submitter_id, unique: true, where: 'submitter_id IS NOT NULL'
    end
  end
end
