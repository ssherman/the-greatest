class CreateBooksGoodreadsSearches < ActiveRecord::Migration[8.1]
  def change
    create_table :books_goodreads_searches do |t|
      t.string :query, null: false
      t.integer :outcome, null: false
      t.datetime :fetched_at, null: false
      t.integer :http_status
      t.integer :parser_version
      t.jsonb :rows, default: [], null: false

      t.timestamps
    end
    add_index :books_goodreads_searches, :query, unique: true
  end
end
