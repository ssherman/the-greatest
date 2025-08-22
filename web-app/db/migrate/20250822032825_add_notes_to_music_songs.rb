class AddNotesToMusicSongs < ActiveRecord::Migration[8.0]
  def change
    add_column :music_songs, :notes, :text
  end
end
