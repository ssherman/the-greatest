class CreateBooksCredits < ActiveRecord::Migration[8.0]
  def change
    create_table :books_credits do |t|
      t.references :author, null: false, foreign_key: {to_table: :books_authors}
      t.references :creditable, polymorphic: true, null: false
      t.integer :role, null: false, default: 0
      t.integer :position

      t.timestamps
    end

    add_index :books_credits, [:author_id, :role]
  end
end
