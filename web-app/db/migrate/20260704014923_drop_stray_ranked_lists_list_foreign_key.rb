class DropStrayRankedListsListForeignKey < ActiveRecord::Migration[8.1]
  # `20250710152255_create_ranked_lists` created a `ranked_lists.list_id -> lists`
  # FK via `t.references :list, foreign_key: true`, and no later migration removed
  # it. Yet that FK is absent from db/schema.rb and from every live database
  # (dev/prod restore, CI schema:load) — it was dropped somewhere in the real DB
  # lineage, and schema.rb was dumped from that state. So only a fresh
  # `rails db:migrate` from zero would re-create it, diverging from schema.rb.
  #
  # Formalize the drop so a from-scratch migrate matches schema.rb (no FK). This
  # keeps `ranked_lists.list_id` intentionally FK-less (it's remapped shift-only by
  # Services::BooksMigration during the lists ID-range reservation). Idempotent via
  # if_exists — a no-op in every environment that already lacks the FK.
  def up
    remove_foreign_key :ranked_lists, :lists, column: :list_id, if_exists: true
  end

  def down
    add_foreign_key :ranked_lists, :lists, column: :list_id, if_not_exists: true
  end
end
