class CreateMusicArtists < ActiveRecord::Migration[8.0]
  def change
    create_table :music_artists do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.integer :kind, null: false, default: 0
      t.string :country, limit: 2
      t.date :born_on
      t.date :died_on
      t.date :formed_on
      t.date :disbanded_on

      t.timestamps
    end

    add_index :music_artists, :slug, unique: true
    add_index :music_artists, :kind
  end
end
