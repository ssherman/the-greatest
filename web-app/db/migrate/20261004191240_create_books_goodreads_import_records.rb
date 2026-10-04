class CreateBooksGoodreadsImportRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :books_goodreads_import_records do |t|
      t.references :import, null: false, index: false,
        foreign_key: {to_table: :books_goodreads_imports, on_delete: :cascade}
      t.references :record, polymorphic: true, null: false
      t.integer :action, null: false
      t.timestamps
    end

    add_index :books_goodreads_import_records, [:import_id, :record_type, :record_id], unique: true,
      name: "index_books_goodreads_import_records_uniqueness"
  end
end
