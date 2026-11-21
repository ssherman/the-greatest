class AddGuidanceToPenalties < ActiveRecord::Migration[8.1]
  def change
    add_column :penalties, :guidance, :text
  end
end
