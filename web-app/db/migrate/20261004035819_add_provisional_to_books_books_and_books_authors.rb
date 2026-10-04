class AddProvisionalToBooksBooksAndBooksAuthors < ActiveRecord::Migration[8.1]
  def change
    add_column :books_books, :provisional, :boolean, default: false, null: false
    add_column :books_authors, :provisional, :boolean, default: false, null: false

    # Partial: nearly every row is false, so a full index would never serve the
    # catalog scope. This one serves "find the provisional rows" for the admin queue.
    add_index :books_books, :provisional, where: "provisional"
    add_index :books_authors, :provisional, where: "provisional"
  end
end
