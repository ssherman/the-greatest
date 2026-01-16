class AddCreatorSpecificToLists < ActiveRecord::Migration[8.1]
  def change
    add_column :lists, :creator_specific, :boolean
  end
end
