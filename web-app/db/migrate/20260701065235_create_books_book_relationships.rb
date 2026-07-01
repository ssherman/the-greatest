class CreateBooksBookRelationships < ActiveRecord::Migration[8.0]
  def change
    create_table :books_book_relationships do |t|
      t.references :book, null: false, foreign_key: {to_table: :books_books}
      t.references :related_book, null: false, foreign_key: {to_table: :books_books}
      t.integer :relation_type, null: false, default: 0

      t.timestamps
    end

    add_index :books_book_relationships, [:book_id, :related_book_id, :relation_type], unique: true, name: "index_books_book_relationships_unique"
  end
end
