class AddAmazonEnrichedAtToBooksBooks < ActiveRecord::Migration[8.1]
  def change
    add_column :books_books, :amazon_enriched_at, :datetime
  end
end
