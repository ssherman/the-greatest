class AddGenderToBooksAuthors < ActiveRecord::Migration[8.1]
  def change
    add_column :books_authors, :gender, :integer
    add_index :books_authors, :gender
  end
end
