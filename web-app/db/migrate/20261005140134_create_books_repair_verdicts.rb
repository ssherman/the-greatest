class CreateBooksRepairVerdicts < ActiveRecord::Migration[8.1]
  def change
    # No foreign keys, on purpose (Goodreads import spec §3): books, authors and
    # users are truncated and re-migrated before launch, and these verdicts must
    # survive that, keyed by preserved ids.
    create_table :books_repair_verdicts do |t|
      t.integer :kind, null: false
      t.string :subject_key, null: false
      t.jsonb :payload, null: false, default: {}
      t.integer :decided_by, null: false
      t.integer :confidence
      t.integer :status, null: false, default: 0
      t.text :reason
      t.bigint :ai_chat_id
      t.bigint :decided_by_user_id
      t.datetime :reviewed_at
      t.datetime :applied_at
      t.text :error
      t.timestamps
    end
    add_index :books_repair_verdicts, [:kind, :subject_key], unique: true
    add_index :books_repair_verdicts, [:status, :kind]
  end
end
