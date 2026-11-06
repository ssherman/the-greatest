class CreateBooksRebuildEditionEvidences < ActiveRecord::Migration[8.1]
  def change
    create_table :books_rebuild_edition_evidences do |t|
      t.bigint :goodreads_book_id, null: false
      t.string :signature, null: false
      t.string :isbn13
      t.integer :world_cat, null: false
      t.string :world_cat_title
      t.string :world_cat_creator
      t.integer :world_cat_year
      t.string :ol_work_keys, array: true, null: false, default: []
      t.datetime :checked_at, null: false

      t.timestamps
    end
    add_index :books_rebuild_edition_evidences, [:goodreads_book_id, :signature], unique: true,
      name: "index_books_rebuild_edition_evidences_on_natural_key"
  end
end
