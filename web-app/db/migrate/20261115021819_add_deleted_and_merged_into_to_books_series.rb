class AddDeletedAndMergedIntoToBooksSeries < ActiveRecord::Migration[8.1]
  def change
    add_column :books_series, :deleted, :boolean, default: false, null: false
    add_index :books_series, :deleted
    add_reference :books_series, :merged_into, null: true, index: true,
      foreign_key: {to_table: :books_series, on_delete: :nullify}
  end
end
