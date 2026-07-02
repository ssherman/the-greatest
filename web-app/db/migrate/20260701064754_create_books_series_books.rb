class CreateBooksSeriesBooks < ActiveRecord::Migration[8.0]
  def change
    create_table :books_series_books do |t|
      t.references :series, null: false, foreign_key: {to_table: :books_series}
      t.references :book, null: false, foreign_key: {to_table: :books_books}
      t.decimal :position, precision: 8, scale: 2
      t.string :position_label
      t.boolean :numbered, null: false, default: true

      t.timestamps
    end

    add_index :books_series_books, [:series_id, :book_id], unique: true
  end
end
