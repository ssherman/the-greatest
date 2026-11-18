class CreateBooksPublisherTitles < ActiveRecord::Migration[8.1]
  def change
    create_table :books_publisher_titles do |t|
      t.string :source, null: false
      t.string :source_key
      t.string :isbn13s, array: true, default: [], null: false
      t.string :title
      t.string :subtitle
      t.jsonb :contributors, default: [], null: false
      t.date :on_sale_on
      t.jsonb :formats, default: [], null: false
      t.string :imprint_name
      t.string :publisher_name
      t.string :language
      t.jsonb :genres, default: [], null: false
      t.string :series_name
      t.string :series_position
      t.string :age_range
      t.text :description
      t.string :cover_url
      t.integer :status, default: 0, null: false
      t.integer :hold_reason
      t.datetime :first_read_at
      t.datetime :last_read_at
      t.integer :parser_version

      t.timestamps
    end
    add_index :books_publisher_titles, [:source, :source_key], unique: true, where: "source_key IS NOT NULL"
    add_index :books_publisher_titles, :isbn13s, using: :gin
    add_index :books_publisher_titles, [:source, :status]
    add_index :books_publisher_titles, :on_sale_on
  end
end
