class AddFinishesLegacyImportIdToBooksGoodreadsImports < ActiveRecord::Migration[8.1]
  def change
    add_column :books_goodreads_imports, :finishes_legacy_import_id, :integer
    add_index :books_goodreads_imports, :finishes_legacy_import_id, unique: true,
      where: "finishes_legacy_import_id IS NOT NULL"
  end
end
