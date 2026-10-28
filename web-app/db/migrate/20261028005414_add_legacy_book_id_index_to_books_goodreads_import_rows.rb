class AddLegacyBookIdIndexToBooksGoodreadsImportRows < ActiveRecord::Migration[8.1]
  def change
    add_index :books_goodreads_import_rows, :legacy_book_id
  end
end
