class CreateMusicAlbums < ActiveRecord::Migration[8.0]
  def change
    create_table :music_albums do |t|
      t.string :title, null: false
      t.string :slug, null: false
      t.text :description
      t.references :primary_artist, null: false, foreign_key: {to_table: :music_artists}, index: true
      t.integer :release_year

      t.timestamps
    end

    add_index :music_albums, :slug, unique: true
  end
end
