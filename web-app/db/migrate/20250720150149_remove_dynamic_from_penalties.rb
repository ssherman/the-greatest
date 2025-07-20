class RemoveDynamicFromPenalties < ActiveRecord::Migration[8.0]
  def change
    remove_column :penalties, :dynamic, :boolean
  end
end
