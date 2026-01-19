class AddReleaseYearIndexesToMusic < ActiveRecord::Migration[8.1]
  def change
    add_index :music_albums, :release_year
    add_index :music_songs, :release_year
  end
end
