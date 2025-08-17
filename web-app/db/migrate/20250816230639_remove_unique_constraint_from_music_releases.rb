class RemoveUniqueConstraintFromMusicReleases < ActiveRecord::Migration[8.0]
  def change
    remove_index :music_releases, name: "index_music_releases_on_album_name_format_unique"
  end
end
