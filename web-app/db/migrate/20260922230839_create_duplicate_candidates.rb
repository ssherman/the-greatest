class CreateDuplicateCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :duplicate_candidates do |t|
      # Both records share item_type. No foreign keys on the ids, matching
      # ranked_items: a merge destroys one side and the row is history.
      t.string :item_type, null: false
      t.bigint :item_a_id, null: false
      t.bigint :item_b_id, null: false
      t.integer :source, null: false
      t.integer :status, null: false, default: 0
      t.jsonb :evidence, null: false, default: {}
      t.integer :occurrences, null: false, default: 1
      t.references :match_decision, null: true, foreign_key: {on_delete: :nullify}
      t.datetime :resolved_at
      t.references :resolved_by, null: true, foreign_key: {to_table: :users, on_delete: :nullify}
      t.text :resolution_note

      t.timestamps
    end

    # One row per unordered pair: a < b is enforced, so (a, b) is canonical.
    add_check_constraint :duplicate_candidates, "item_a_id < item_b_id", name: "duplicate_candidates_a_before_b"
    add_index :duplicate_candidates, [:item_type, :item_a_id, :item_b_id], unique: true, name: "index_duplicate_candidates_on_pair"
    add_index :duplicate_candidates, [:item_type, :item_b_id], name: "index_duplicate_candidates_on_type_and_b"
    add_index :duplicate_candidates, [:status, :created_at]
  end
end
