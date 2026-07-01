class CreateBooksEditions < ActiveRecord::Migration[8.0]
  def change
    create_table :books_editions do |t|
      t.references :book, null: false, foreign_key: {to_table: :books_books}
      t.string :title
      t.string :subtitle
      t.integer :edition_type, null: false, default: 0
      t.references :language, foreign_key: {to_table: :languages}
      t.integer :book_binding
      t.integer :publication_year
      t.integer :volume_number
      t.integer :page_count
      t.integer :popularity
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :books_editions, :edition_type
    add_index :books_editions, :volume_number
  end
end
