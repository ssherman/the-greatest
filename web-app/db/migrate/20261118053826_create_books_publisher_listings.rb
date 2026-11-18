class CreateBooksPublisherListings < ActiveRecord::Migration[8.1]
  def change
    create_table :books_publisher_listings do |t|
      t.string :source, null: false
      t.string :url, null: false
      t.string :external_key
      t.integer :state, default: 1, null: false
      t.string :signal
      t.integer :outcome
      t.integer :http_status
      t.integer :parser_version
      t.integer :last_attempt_outcome
      t.datetime :last_attempt_at
      t.integer :attempts, default: 0, null: false
      t.datetime :queued_at
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :read_at
      t.references :publisher_title, foreign_key: {to_table: :books_publisher_titles, on_delete: :nullify}

      t.timestamps
    end
    add_index :books_publisher_listings, [:source, :url], unique: true
    add_index :books_publisher_listings, [:source, :state]
    add_index :books_publisher_listings, [:source, :external_key]
  end
end
