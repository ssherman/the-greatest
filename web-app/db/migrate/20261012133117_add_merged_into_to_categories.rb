class AddMergedIntoToCategories < ActiveRecord::Migration[8.1]
  def change
    add_reference :categories, :merged_into, foreign_key: {to_table: :categories}, index: true, null: true
  end
end
