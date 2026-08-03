class CreateBooksBookCountries < ActiveRecord::Migration[8.1]
  def change
    create_table :books_book_countries do |t|
      t.references :book, null: false, foreign_key: {to_table: :books_books}
      t.references :country, null: false, foreign_key: {to_table: :books_countries}

      t.timestamps
    end

    add_index :books_book_countries, [:book_id, :country_id], unique: true
  end
end
