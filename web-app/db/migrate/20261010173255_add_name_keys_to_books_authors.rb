class AddNameKeysToBooksAuthors < ActiveRecord::Migration[8.1]
  # The finders read name_keys from the moment this deploy is live, so the
  # column is filled here rather than by a task run afterwards: an empty
  # column would make every exact match miss and imports create duplicates.
  def up
    add_column :books_authors, :name_keys, :string, array: true, default: [], null: false
    add_index :books_authors, :name_keys, using: :gin
    Books::Author.reset_column_information
    Services::Books::RefreshAuthorNameKeys.call
  end

  def down
    remove_index :books_authors, :name_keys
    remove_column :books_authors, :name_keys
  end
end
