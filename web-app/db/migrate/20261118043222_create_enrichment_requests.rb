class CreateEnrichmentRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :enrichment_requests do |t|
      t.references :enrichable, polymorphic: true, null: false, index: false
      t.string :kind, null: false
      t.integer :version, null: false, default: 1
      t.integer :status, null: false, default: 0
      t.integer :priority, null: false, default: 1_000_000
      t.string :reason, null: false
      t.string :fingerprint
      t.string :outcome
      t.text :note
      t.jsonb :answer
      t.text :error
      t.jsonb :sources, null: false, default: []
      t.references :enrichment, foreign_key: {on_delete: :nullify}
      t.string :lease_token
      t.datetime :lease_expires_at
      t.integer :attempts, null: false, default: 0
      t.references :claimed_by, foreign_key: {to_table: :users, on_delete: :nullify}
      t.references :resolved_by, foreign_key: {to_table: :users, on_delete: :nullify}
      t.integer :resolved_via
      t.datetime :resolved_at

      t.timestamps
    end

    add_index :enrichment_requests, [:enrichable_type, :enrichable_id, :kind],
      unique: true, name: "index_enrichment_requests_one_per_record_and_kind"
    add_index :enrichment_requests, [:kind, :status, :priority, :id]
  end
end
