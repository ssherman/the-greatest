class RenameOpenLibraryBackfillsToVerifications < ActiveRecord::Migration[8.1]
  def change
    rename_table :books_open_library_backfills, :books_verifications
    rename_column :books_verifications, :outcome, :work_outcome
  end
end
