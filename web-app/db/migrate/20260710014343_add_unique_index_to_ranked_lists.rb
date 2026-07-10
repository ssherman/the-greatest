class AddUniqueIndexToRankedLists < ActiveRecord::Migration[8.1]
  # `20250710152255_create_ranked_lists` already added a composite unique index on
  # [list_id, ranking_configuration_id] named
  # `index_ranked_lists_on_list_and_ranking_config_unique`, and no later migration
  # removed it. Yet — exactly like the sibling `list_id` FK formalized in
  # `20260704014923_drop_stray_ranked_lists_list_foreign_key` — that index is absent
  # from db/schema.rb and from every live database (dev/prod restore, CI schema:load):
  # it was dropped somewhere in the real DB lineage and schema.rb was dumped from that
  # state. A from-scratch `rails db:migrate` re-creates it, so this migration first drops
  # that stray index if present, then adds the canonical one — otherwise a from-zero
  # migrate would maintain two identical unique indexes and dump a schema.rb that
  # diverges from the committed one.
  #
  # The composite unique index is the ranked_lists upsert conflict target
  # (Services::BooksMigration::RankedListMigrator) and formalizes the model's existing
  # `validates :list_id, uniqueness: {scope: :ranking_configuration_id}`. Idempotent via
  # if_exists/if_not_exists — a no-op wherever the target state already holds (e.g. the
  # schema:load path, where neither index is present until this runs).
  def up
    remove_index :ranked_lists, name: "index_ranked_lists_on_list_and_ranking_config_unique", if_exists: true
    add_index :ranked_lists, [:list_id, :ranking_configuration_id],
      unique: true, name: "index_ranked_lists_on_list_and_config_unique", if_not_exists: true
  end

  def down
    remove_index :ranked_lists, name: "index_ranked_lists_on_list_and_config_unique", if_exists: true
  end
end
