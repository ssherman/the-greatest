class CreateLanguages < ActiveRecord::Migration[8.0]
  def change
    create_table :languages do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :iso_639_1, limit: 2
      t.string :iso_639_3, limit: 3

      t.timestamps
    end

    add_index :languages, :slug, unique: true
    add_index :languages, :iso_639_3, unique: true
    add_index :languages, :name
  end
end
