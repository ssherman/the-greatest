class CreateBooksEditionCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :books_edition_candidates do |t|
      t.references :book, null: false, foreign_key: {to_table: :books_books, on_delete: :cascade}
      t.string :edition_key, null: false
      t.string :work_key
      t.string :title
      t.string :subtitle
      t.string :language_code
      t.integer :publish_year
      t.jsonb :identifiers, null: false, default: {}
      t.timestamps
    end
    add_index :books_edition_candidates, [:book_id, :edition_key], unique: true
  end
end
