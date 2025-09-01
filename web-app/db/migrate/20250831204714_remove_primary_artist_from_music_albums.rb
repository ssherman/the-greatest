class RemovePrimaryArtistFromMusicAlbums < ActiveRecord::Migration[8.0]
  def change
    remove_reference :music_albums, :primary_artist, null: false, foreign_key: {to_table: :music_artists}
  end
end
