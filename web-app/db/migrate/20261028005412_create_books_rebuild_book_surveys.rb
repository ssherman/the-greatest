class CreateBooksRebuildBookSurveys < ActiveRecord::Migration[8.1]
  def change
    create_table :books_rebuild_book_surveys do |t|
      t.references :book, null: false, index: {unique: true}, foreign_key: {to_table: :books_books, on_delete: :cascade}
      t.integer :classification, null: false
      t.integer :edition_count, null: false, default: 0
      t.integer :row_count, null: false, default: 0
      t.jsonb :groups, null: false, default: []
      t.boolean :title_agrees
      t.boolean :authors_agree
      t.boolean :wrong_book, null: false, default: false
      t.datetime :surveyed_at, null: false

      t.timestamps
    end
    add_index :books_rebuild_book_surveys, :classification
    add_index :books_rebuild_book_surveys, :wrong_book
  end
end
