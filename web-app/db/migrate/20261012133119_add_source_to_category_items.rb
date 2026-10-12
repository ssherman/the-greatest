class AddSourceToCategoryItems < ActiveRecord::Migration[8.1]
  def change
    # Adding a column with a constant default is metadata-only on PostgreSQL 11+,
    # so this does not rewrite the ~1.8M-row table during the deploy.
    add_column :category_items, :source, :integer, null: false, default: 0
  end
end
