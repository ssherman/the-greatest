class CreateBooksBookSubmissions < ActiveRecord::Migration[8.1]
  def change
    create_table :books_book_submissions do |t|
      t.references :user, foreign_key: {on_delete: :nullify}, index: false
      t.references :user_list, foreign_key: {on_delete: :nullify}
      t.references :book, foreign_key: {to_table: :books_books, on_delete: :nullify}
      t.references :match_decision, foreign_key: {on_delete: :nullify}
      t.references :user_list_item, foreign_key: {on_delete: :nullify}

      t.integer :input_method, null: false
      t.text :raw_input
      t.string :typed_title
      t.jsonb :typed_author_names, default: []
      t.bigint :goodreads_book_id
      t.string :asin
      t.string :isbn13
      t.string :isbn10
      t.string :resolved_title
      t.jsonb :resolved_author_names, default: []
      t.jsonb :supplied
      t.jsonb :lookup, default: {}
      t.string :signature
      t.string :fingerprint

      t.integer :status, null: false, default: 0
      t.integer :review_status, null: false, default: 0
      t.boolean :created_book, null: false, default: false
      t.text :error

      t.datetime :processing_started_at
      t.datetime :next_attempt_at
      t.datetime :announced_at
      t.datetime :dismissed_at

      t.references :reviewed_by, foreign_key: {to_table: :users, on_delete: :nullify}
      t.integer :reviewed_via
      t.datetime :reviewed_at
      t.text :review_note
      t.jsonb :review_sources, default: []

      t.string :lease_token
      t.datetime :lease_expires_at
      t.references :claimed_by, foreign_key: {to_table: :users, on_delete: :nullify}
      t.integer :attempts, null: false, default: 0

      t.timestamps
    end

    add_index :books_book_submissions, [:user_id, :created_at]
    add_index :books_book_submissions, :signature
    add_index :books_book_submissions, [:status, :review_status]
  end
end
