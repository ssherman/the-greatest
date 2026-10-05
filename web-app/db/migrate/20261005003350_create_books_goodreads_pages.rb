class CreateBooksGoodreadsPages < ActiveRecord::Migration[8.1]
  def change
    create_table :books_goodreads_pages do |t|
      t.bigint :goodreads_book_id, null: false
      t.integer :source, null: false, default: 0
      t.integer :outcome, null: false
      t.datetime :fetched_at, null: false
      t.integer :http_status
      t.integer :parser_version
      t.string :title
      t.jsonb :series, null: false, default: []
      t.jsonb :authors, null: false, default: []
      t.integer :original_publication_year
      t.string :isbn13
      t.string :isbn10
      t.string :asin

      t.timestamps
    end
    add_index :books_goodreads_pages, :goodreads_book_id, unique: true
  end
end
