class ConvertBooksAlternateTitlesToShared < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :books_alternate_titles, column: :book_id
    remove_index :books_alternate_titles, [:book_id, :normalized_title]
    remove_index :books_alternate_titles, :book_id
    rename_table :books_alternate_titles, :alternate_titles
    rename_column :alternate_titles, :book_id, :titleable_id
    add_column :alternate_titles, :titleable_type, :string
    execute "UPDATE alternate_titles SET titleable_type = 'Books::Book'"
    change_column_null :alternate_titles, :titleable_type, false
    add_index :alternate_titles, [:titleable_type, :titleable_id, :normalized_title], unique: true, name: "index_alternate_titles_on_titleable_and_normalized_title"
    add_index :alternate_titles, [:titleable_type, :titleable_id]
  end

  def down
    remove_index :alternate_titles, [:titleable_type, :titleable_id]
    remove_index :alternate_titles, name: "index_alternate_titles_on_titleable_and_normalized_title"
    execute "DELETE FROM alternate_titles WHERE titleable_type <> 'Books::Book'"
    remove_column :alternate_titles, :titleable_type
    rename_column :alternate_titles, :titleable_id, :book_id
    rename_table :alternate_titles, :books_alternate_titles
    add_index :books_alternate_titles, :book_id
    add_index :books_alternate_titles, [:book_id, :normalized_title], unique: true
    add_foreign_key :books_alternate_titles, :books_books, column: :book_id, on_delete: :cascade
  end
end
