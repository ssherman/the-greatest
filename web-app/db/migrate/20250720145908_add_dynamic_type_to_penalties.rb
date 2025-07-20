class AddDynamicTypeToPenalties < ActiveRecord::Migration[8.0]
  def change
    add_column :penalties, :dynamic_type, :integer
  end
end
