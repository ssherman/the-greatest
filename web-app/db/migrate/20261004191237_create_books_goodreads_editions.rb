class CreateBooksGoodreadsEditions < ActiveRecord::Migration[8.1]
  def change
    create_table :books_goodreads_editions do |t|
      t.bigint :goodreads_book_id, null: false
      t.string :signature, null: false
      t.string :title, null: false
      t.string :series_name
      t.string :series_number
      t.string :primary_author, null: false
      t.string :additional_authors, array: true, null: false, default: []
      t.string :isbn13
      t.string :isbn10
      t.integer :original_publication_year
      t.integer :year_published
      t.string :publisher
      # Goodreads' "Binding". Not `binding`: that name collides with Kernel#binding.
      t.string :book_format
      t.integer :pages
      t.references :book, foreign_key: {to_table: :books_books, on_delete: :nullify}
      t.references :match_decision, foreign_key: {on_delete: :nullify}
      t.datetime :resolved_at
      t.integer :resolution
      t.integer :verification, null: false, default: 0
      t.timestamps
    end

    add_index :books_goodreads_editions, [:goodreads_book_id, :signature], unique: true
    add_index :books_goodreads_editions, :signature
  end
end
