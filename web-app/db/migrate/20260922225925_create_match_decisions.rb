class CreateMatchDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :match_decisions do |t|
      # The finder class name, so the audit page can filter by domain/entity.
      t.string :finder, null: false
      # The matched record, or the created one once the importer saves it.
      # Nullable: an unmatched decision has no record until the importer
      # creates one, and a finder called on its own never gets one.
      t.references :record, polymorphic: true, null: true
      # What the caller was resolving for (a list item), when it said.
      t.references :subject, polymorphic: true, null: true
      t.integer :outcome, null: false
      t.integer :confidence, null: false
      t.integer :decided_by, null: false
      t.boolean :verify, null: false, default: false
      t.jsonb :query, null: false, default: {}
      t.jsonb :candidates, null: false, default: []
      t.integer :selected_index
      t.text :reason
      t.references :ai_chat, null: true, foreign_key: {on_delete: :nullify}
      t.string :sources_failed, array: true, null: false, default: []
      t.boolean :needs_review, null: false, default: false
      t.datetime :reviewed_at
      t.references :reviewed_by, null: true, foreign_key: {to_table: :users, on_delete: :nullify}
      t.text :review_note

      t.timestamps
    end

    add_index :match_decisions, :finder
    add_index :match_decisions, [:needs_review, :reviewed_at]
    add_index :match_decisions, :created_at
  end
end
