class AddEnrichmentFieldsToBooksGoodreadsPages < ActiveRecord::Migration[8.1]
  def change
    add_column :books_goodreads_pages, :description, :text
    add_column :books_goodreads_pages, :page_count, :integer
    add_column :books_goodreads_pages, :format, :string
    add_column :books_goodreads_pages, :best_book_id, :bigint
    add_column :books_goodreads_pages, :genres, :jsonb, default: [], null: false
  end
end
