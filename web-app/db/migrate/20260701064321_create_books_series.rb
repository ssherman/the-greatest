class CreateBooksSeries < ActiveRecord::Migration[8.0]
  def change
    create_table :books_series do |t|
      t.string :title, null: false
      t.string :slug, null: false
      t.text :description
      t.references :representative_book, foreign_key: {to_table: :books_books}

      t.timestamps
    end

    add_index :books_series, :slug, unique: true
    add_index :books_series, :title
  end
end
