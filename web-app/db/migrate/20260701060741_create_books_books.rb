class CreateBooksBooks < ActiveRecord::Migration[8.0]
  def change
    create_table :books_books do |t|
      t.string :title, null: false
      t.string :subtitle
      t.string :sort_title
      t.string :alternate_titles, array: true, default: [], null: false
      t.string :slug, null: false
      t.text :description
      t.integer :first_published_year
      t.references :original_language, foreign_key: {to_table: :languages}
      t.integer :book_kind, null: false, default: 0

      t.timestamps
    end

    add_index :books_books, :slug, unique: true
    add_index :books_books, :book_kind
    add_index :books_books, :first_published_year
    add_index :books_books, :alternate_titles, using: :gin
  end
end
