class CreateBooksBookAuthors < ActiveRecord::Migration[8.0]
  def change
    create_table :books_book_authors do |t|
      t.references :book, null: false, foreign_key: {to_table: :books_books}
      t.references :author, null: false, foreign_key: {to_table: :books_authors}
      t.integer :position
      t.integer :role, null: false, default: 0
      t.string :credited_as

      t.timestamps
    end

    add_index :books_book_authors, [:book_id, :author_id], unique: true
  end
end
