class CreateEnrichments < ActiveRecord::Migration[8.1]
  def change
    create_table :enrichments do |t|
      # One row per AI enrichment run on any record, across domains, like
      # ai_chats. Spec: docs/superpowers/specs/2026-09-24-books-ai-enrichment-framework-design.md §3.
      t.references :enrichable, polymorphic: true, null: false
      t.string :kind, null: false
      t.integer :mode, null: false, default: 0
      t.integer :outcome, null: false
      t.boolean :recognized
      t.integer :confidence
      t.jsonb :facts, null: false, default: {}
      t.jsonb :citations, null: false, default: []
      t.string :provider
      t.string :model
      # Nullable: a skipped run has no chat. Nullify, not cascade: the ledger
      # outlives the chat that produced it.
      t.references :ai_chat, null: true, foreign_key: {on_delete: :nullify}
      t.text :error
      t.string :reason

      t.timestamps
    end

    add_index :enrichments, :kind
    add_index :enrichments, :outcome
    # The research budget is "research rows created today"; this serves it.
    add_index :enrichments, [:mode, :created_at]
  end
end
