class CreateCategories < ActiveRecord::Migration[8.0]
  def change
    create_table :categories do |t|
      t.string :type, null: false              # STI discriminator (Books::Category, Music::Category, etc.)
      t.string :name, null: false
      t.string :slug                           # FriendlyId slug (scoped by type, not unique)
      t.text :description
      t.integer :category_type, default: 0    # enum: genre, location, subject
      t.integer :import_source                # enum: amazon, open_library, openai, goodreads, musicbrainz
      t.string :alternative_names, array: true, default: []
      t.integer :item_count, default: 0
      t.boolean :deleted, default: false
      t.references :parent, foreign_key: {to_table: :categories}, null: true

      t.timestamps
    end

    add_index :categories, :type
    add_index :categories, :name
    add_index :categories, :slug              # No unique constraint - scoped by type
    add_index :categories, [:type, :slug]     # Composite index for scoped lookups
    add_index :categories, :category_type
    add_index :categories, :deleted
  end
end
