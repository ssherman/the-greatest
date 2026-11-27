class AddAdminTargetToBooksBookSubmissions < ActiveRecord::Migration[8.1]
  # An admin agent's request names a books list to add the book to (list_id,
  # list_position) instead of a reader's user list, and records the row it
  # made (list_item_id). origin keeps those rows out of the reader review queue.
  def change
    add_column :books_book_submissions, :origin, :integer, default: 0, null: false
    add_reference :books_book_submissions, :list, foreign_key: {on_delete: :nullify}, index: true
    add_column :books_book_submissions, :list_position, :integer
    add_reference :books_book_submissions, :list_item, foreign_key: {on_delete: :nullify}, index: true
    add_check_constraint :books_book_submissions, "user_list_id IS NULL OR list_id IS NULL", name: "book_submissions_one_list_target"
  end
end
