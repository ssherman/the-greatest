class CreateCategoryCleanupDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :category_cleanup_decisions do |t|
      t.references :category, null: false, foreign_key: true
      t.string :run, null: false
      t.string :stage, null: false
      t.integer :action, null: false
      t.integer :decided_by, null: false
      t.integer :status, null: false, default: 0
      t.string :new_name
      t.references :target_category, foreign_key: {to_table: :categories}
      t.string :parent_chain, array: true, null: false, default: []
      t.integer :new_category_type
      t.string :place_kind
      t.boolean :ambiguous, null: false, default: false
      t.text :reason
      t.references :ai_chat, foreign_key: true
      t.jsonb :category_snapshot, null: false, default: {}
      t.text :error
      t.timestamps
    end
    add_index :category_cleanup_decisions, [:run, :status]
    add_index :category_cleanup_decisions, [:run, :stage]
    add_index :category_cleanup_decisions, [:run, :category_id]
  end
end
