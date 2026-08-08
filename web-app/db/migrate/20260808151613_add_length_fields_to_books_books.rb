class AddLengthFieldsToBooksBooks < ActiveRecord::Migration[8.1]
  def change
    add_column :books_books, :book_length, :integer
    add_column :books_books, :page_range, :string
    add_column :books_books, :word_count, :integer
  end
end
