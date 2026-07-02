class ChangeSeriesRepresentativeBookFkToNullify < ActiveRecord::Migration[8.0]
  def up
    remove_foreign_key :books_series, column: :representative_book_id
    add_foreign_key :books_series, :books_books, column: :representative_book_id, on_delete: :nullify
  end

  def down
    remove_foreign_key :books_series, column: :representative_book_id
    add_foreign_key :books_series, :books_books, column: :representative_book_id
  end
end
