class CreateMusicSongArtists < ActiveRecord::Migration[8.0]
  def change
    create_table :music_song_artists do |t|
      t.references :song, null: false, foreign_key: {to_table: :music_songs}
      t.references :artist, null: false, foreign_key: {to_table: :music_artists}
      t.integer :position, default: 1

      t.timestamps
    end

    add_index :music_song_artists, [:song_id, :artist_id], unique: true
    add_index :music_song_artists, [:song_id, :position]
  end
end
