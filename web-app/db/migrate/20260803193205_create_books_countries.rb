class CreateBooksCountries < ActiveRecord::Migration[8.1]
  def change
    create_table :books_countries do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.string :labels, array: true, null: false, default: []
      t.integer :book_count, null: false, default: 0

      t.timestamps
    end

    add_index :books_countries, :slug, unique: true
    add_index :books_countries, :labels, using: :gin
    add_index :books_countries, :book_count
  end
end
