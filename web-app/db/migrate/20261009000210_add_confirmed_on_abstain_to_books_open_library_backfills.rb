class AddConfirmedOnAbstainToBooksOpenLibraryBackfills < ActiveRecord::Migration[8.1]
  def change
    add_column :books_open_library_backfills, :confirmed_on_abstain, :boolean, null: false, default: false
  end
end
