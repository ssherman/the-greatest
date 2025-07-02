class CreateMusicReleases < ActiveRecord::Migration[8.0]
  def change
    create_table :music_releases do |t|
      t.references :album, null: false, foreign_key: {to_table: :music_albums}
      t.string :release_name
      t.integer :format, null: false, default: 0
      t.jsonb :metadata
      t.date :release_date

      t.timestamps
    end

    add_index :music_releases, [:album_id, :release_name, :format], unique: true, name: "index_music_releases_on_album_name_format_unique"
  end
end
