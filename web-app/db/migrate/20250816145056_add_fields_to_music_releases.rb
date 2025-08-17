class AddFieldsToMusicReleases < ActiveRecord::Migration[8.0]
  def change
    add_column :music_releases, :country, :string
    add_column :music_releases, :status, :integer, default: 0, null: false
    add_column :music_releases, :labels, :string, array: true, default: []

    add_index :music_releases, :country
    add_index :music_releases, :status
  end
end
