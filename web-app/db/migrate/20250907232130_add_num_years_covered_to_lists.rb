class AddNumYearsCoveredToLists < ActiveRecord::Migration[8.0]
  def change
    add_column :lists, :num_years_covered, :integer
  end
end
