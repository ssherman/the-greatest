class AddVoterCountEstimatedToLists < ActiveRecord::Migration[8.1]
  def change
    add_column :lists, :voter_count_estimated, :boolean
  end
end
