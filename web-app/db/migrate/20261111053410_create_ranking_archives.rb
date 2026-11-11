class CreateRankingArchives < ActiveRecord::Migration[8.1]
  def change
    create_table :ranking_archives do |t|
      t.string :type, null: false
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.bigint :item_ids, array: true, null: false, default: []
      t.integer :positions, array: true, null: false, default: []
      t.decimal :scores, array: true, precision: 10, scale: 2, null: false, default: []
      t.integer :items_count, null: false, default: 0
      t.datetime :captured_at, null: false
      t.date :period
      t.references :ranking_configuration, null: true, foreign_key: {on_delete: :nullify}
      t.integer :legacy_ranking_configuration_id
      t.boolean :hidden, null: false, default: false

      t.timestamps
    end
    add_index :ranking_archives, [:type, :slug], unique: true
    add_index :ranking_archives, [:ranking_configuration_id, :period], unique: true, where: "period IS NOT NULL",
      name: "index_ranking_archives_on_config_and_period"
    add_index :ranking_archives, :legacy_ranking_configuration_id, unique: true,
      where: "legacy_ranking_configuration_id IS NOT NULL", name: "index_ranking_archives_on_legacy_config"
    add_index :ranking_archives, [:type, :hidden, :captured_at]
  end
end
