class CreateBooksGoodreadsImports < ActiveRecord::Migration[8.1]
  def change
    create_table :books_goodreads_imports do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :source, null: false, default: 0
      t.integer :legacy_import_id
      t.integer :status, null: false, default: 0
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :review_status, null: false, default: 0
      t.references :reviewed_by, foreign_key: {to_table: :users}
      t.datetime :reviewed_at
      t.integer :rows_count, null: false, default: 0
      t.integer :editions_count, null: false, default: 0
      t.integer :matched_count, null: false, default: 0
      t.integer :created_count, null: false, default: 0
      t.integer :flagged_count, null: false, default: 0
      t.integer :parked_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.integer :ai_calls_count, null: false, default: 0
      t.timestamps
    end

    add_index :books_goodreads_imports, :legacy_import_id, unique: true, where: "legacy_import_id IS NOT NULL"
    # One import in progress per user (spec §3): queued, parsing, resolving,
    # verifying or writing.
    add_index :books_goodreads_imports, :user_id, unique: true, where: "status IN (0, 1, 2, 3, 4)",
      name: "index_books_goodreads_imports_one_in_progress_per_user"
  end
end
