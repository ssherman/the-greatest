class AddDefaultEditionToBooksBooks < ActiveRecord::Migration[8.0]
  def change
    add_reference :books_books, :default_edition, foreign_key: {to_table: :books_editions}
  end
end
