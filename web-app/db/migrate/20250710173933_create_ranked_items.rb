class CreateRankedItems < ActiveRecord::Migration[8.0]
  def change
    create_table :ranked_items do |t|
      t.integer :rank
      t.decimal :score, precision: 10, scale: 2
      t.references :item, polymorphic: true, null: false
      t.references :ranking_configuration, null: false, foreign_key: true

      t.timestamps
    end

    # Ensure unique item per ranking configuration
    add_index :ranked_items, [:item_id, :item_type, :ranking_configuration_id],
      unique: true,
      name: "index_ranked_items_on_item_and_ranking_config_unique"

    # Index for ranking queries
    add_index :ranked_items, [:ranking_configuration_id, :rank],
      name: "index_ranked_items_on_config_and_rank"

    # Index for score-based queries
    add_index :ranked_items, [:ranking_configuration_id, :score],
      name: "index_ranked_items_on_config_and_score"
  end
end
