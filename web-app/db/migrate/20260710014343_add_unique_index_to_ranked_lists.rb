class AddUniqueIndexToRankedLists < ActiveRecord::Migration[8.1]
  def change
    add_index :ranked_lists, [:list_id, :ranking_configuration_id],
      unique: true, name: "index_ranked_lists_on_list_and_config_unique"
  end
end
