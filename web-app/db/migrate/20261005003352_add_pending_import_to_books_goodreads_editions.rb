class AddPendingImportToBooksGoodreadsEditions < ActiveRecord::Migration[8.1]
  def change
    add_reference :books_goodreads_editions, :pending_import, index: true,
      foreign_key: {to_table: :books_goodreads_imports, on_delete: :nullify}
  end
end
