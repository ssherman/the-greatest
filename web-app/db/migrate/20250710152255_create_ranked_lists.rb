class CreateRankedLists < ActiveRecord::Migration[8.0]
  def change
    create_table :ranked_lists do |t|
      t.integer :weight
      t.references :list, null: false, foreign_key: true
      t.references :ranking_configuration, null: false, foreign_key: true

      t.timestamps
    end

    # Ensure unique list per ranking configuration
    add_index :ranked_lists, [:list_id, :ranking_configuration_id],
      unique: true,
      name: "index_ranked_lists_on_list_and_ranking_config_unique"
  end
end
