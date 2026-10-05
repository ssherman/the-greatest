class AddReplayFindingToBooksGoodreadsImportRows < ActiveRecord::Migration[8.1]
  def change
    # What the legacy replay found for the row (Goodreads import spec §12.4), and
    # the book legacy chose for it. No FK: the book is named across books
    # re-migrations, which recreate it under the same preserved id.
    add_column :books_goodreads_import_rows, :replay_finding, :integer
    add_column :books_goodreads_import_rows, :legacy_book_id, :bigint
    add_index :books_goodreads_import_rows, :replay_finding
  end
end
