class CreateMusicAlbumArtists < ActiveRecord::Migration[8.0]
  def change
    create_table :music_album_artists do |t|
      t.references :album, null: false, foreign_key: {to_table: :music_albums}
      t.references :artist, null: false, foreign_key: {to_table: :music_artists}
      t.integer :position, default: 1

      t.timestamps
    end

    add_index :music_album_artists, [:album_id, :artist_id], unique: true
    add_index :music_album_artists, [:album_id, :position]
  end
end
