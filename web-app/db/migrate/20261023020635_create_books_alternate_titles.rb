class CreateBooksAlternateTitles < ActiveRecord::Migration[8.1]
  def change
    create_table :books_alternate_titles do |t|
      t.references :book, null: false, foreign_key: {to_table: :books_books, on_delete: :cascade}
      t.string :title, null: false
      t.string :normalized_title, null: false
      t.integer :source, null: false
      t.integer :status, null: false, default: 0
      t.integer :verdict
      t.integer :category
      t.float :confidence
      t.text :reason
      t.references :ai_chat, foreign_key: {on_delete: :nullify}
      t.integer :decided_by
      t.bigint :decided_by_user_id
      t.datetime :decided_at
      t.datetime :judged_at
      t.datetime :undo_checked_at

      t.timestamps
    end

    add_foreign_key :books_alternate_titles, :users, column: :decided_by_user_id, on_delete: :nullify
    add_index :books_alternate_titles, :decided_by_user_id
    add_index :books_alternate_titles, [:book_id, :normalized_title], unique: true
    add_index :books_alternate_titles, :status
  end
end
