class CreateBooksVerificationFindings < ActiveRecord::Migration[8.1]
  def change
    create_table :books_verification_findings do |t|
      t.references :verification, null: false, foreign_key: {to_table: :books_verifications, on_delete: :cascade}
      t.references :book, null: false, foreign_key: {to_table: :books_books, on_delete: :cascade}
      t.integer :kind, null: false
      t.integer :identifier_type, null: false
      t.string :value, null: false
      t.bigint :identifier_id
      t.integer :source
      t.integer :previous_source
      t.references :other_book, foreign_key: {to_table: :books_books, on_delete: :cascade}
      t.string :work_key
      t.jsonb :evidence, null: false, default: {}
      t.timestamps
    end
    add_index :books_verification_findings, [:verification_id, :kind, :identifier_type, :value],
      unique: true, name: "index_books_verification_findings_unique"
    add_index :books_verification_findings, :kind
  end
end
