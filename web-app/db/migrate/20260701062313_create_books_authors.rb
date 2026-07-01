class CreateBooksAuthors < ActiveRecord::Migration[8.0]
  def change
    create_table :books_authors do |t|
      t.string :name, null: false
      t.string :sort_name
      t.string :slug, null: false
      t.integer :kind, null: false, default: 0
      t.integer :birth_year
      t.integer :death_year
      t.text :description
      t.string :alternate_names, array: true, default: [], null: false

      t.timestamps
    end

    add_index :books_authors, :slug, unique: true
    add_index :books_authors, :kind
    add_index :books_authors, :alternate_names, using: :gin
  end
end
