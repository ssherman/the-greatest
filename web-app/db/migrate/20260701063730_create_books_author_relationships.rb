class CreateBooksAuthorRelationships < ActiveRecord::Migration[8.0]
  def change
    create_table :books_author_relationships do |t|
      t.references :from_author, null: false, foreign_key: {to_table: :books_authors}
      t.references :to_author, null: false, foreign_key: {to_table: :books_authors}
      t.integer :relation_type, null: false, default: 0

      t.timestamps
    end

    add_index :books_author_relationships, [:from_author_id, :to_author_id, :relation_type], unique: true, name: "index_books_author_relationships_unique"
  end
end
