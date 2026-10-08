class CreateBooksOpenLibraryBackfills < ActiveRecord::Migration[8.1]
  def change
    create_table :books_open_library_backfills do |t|
      t.references :book, null: false, index: {unique: true},
        foreign_key: {to_table: :books_books, on_delete: :cascade}
      t.integer :outcome, null: false
      t.integer :lookup
      t.string :old_keys, array: true, null: false, default: []
      t.string :new_key
      t.string :duplicate_keys, array: true, null: false, default: []
      t.bigint :pair_book_id
      t.jsonb :author_changes, null: false, default: {}
      t.string :dump_date
      t.integer :matcher_version
      t.string :run_id, null: false
      t.integer :attempts, null: false, default: 1
      t.text :error
      t.timestamps
    end
    add_foreign_key :books_open_library_backfills, :books_books, column: :pair_book_id, on_delete: :nullify
    add_index :books_open_library_backfills, :outcome
    add_index :books_open_library_backfills, :run_id
  end
end
