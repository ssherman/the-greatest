class ChangeDefaultEditionFkToNullify < ActiveRecord::Migration[8.0]
  def up
    remove_foreign_key :books_books, column: :default_edition_id
    add_foreign_key :books_books, :books_editions, column: :default_edition_id, on_delete: :nullify
  end

  def down
    remove_foreign_key :books_books, column: :default_edition_id
    add_foreign_key :books_books, :books_editions, column: :default_edition_id
  end
end
