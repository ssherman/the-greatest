class CreateBooksGoodreadsImportRows < ActiveRecord::Migration[8.1]
  def change
    create_table :books_goodreads_import_rows do |t|
      t.references :import, null: false, index: false,
        foreign_key: {to_table: :books_goodreads_imports, on_delete: :cascade}
      t.integer :row_number, null: false
      t.references :goodreads_edition, foreign_key: {to_table: :books_goodreads_editions}
      t.jsonb :raw, null: false, default: {}
      t.string :exclusive_shelf
      t.string :shelves, array: true, null: false, default: []
      t.jsonb :shelf_positions, null: false, default: {}
      t.integer :rating
      t.text :review_body
      t.date :date_read
      t.date :date_added
      t.integer :read_count
      t.string :notes, array: true, null: false, default: []
      t.integer :outcome, null: false, default: 0
      t.string :outcome_detail
      t.text :error
      t.jsonb :applied, null: false, default: {}
      t.timestamps
    end

    add_index :books_goodreads_import_rows, [:import_id, :row_number], unique: true
  end
end
