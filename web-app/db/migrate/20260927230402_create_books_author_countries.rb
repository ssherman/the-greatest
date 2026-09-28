class CreateBooksAuthorCountries < ActiveRecord::Migration[8.1]
  def change
    create_table :books_author_countries do |t|
      t.references :author, null: false, foreign_key: {to_table: :books_authors}
      t.references :country, null: false, foreign_key: {to_table: :books_countries}

      t.timestamps
    end
    add_index :books_author_countries, [:author_id, :country_id], unique: true
  end
end
