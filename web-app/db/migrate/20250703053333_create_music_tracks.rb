class CreateMusicTracks < ActiveRecord::Migration[8.0]
  def change
    create_table :music_tracks do |t|
      t.references :release, null: false, foreign_key: {to_table: :music_releases}
      t.references :song, null: false, foreign_key: {to_table: :music_songs}
      t.integer :medium_number, null: false, default: 1
      t.integer :position, null: false
      t.integer :length_secs
      t.text :notes

      t.timestamps
    end

    add_index :music_tracks, [:release_id, :medium_number, :position], unique: true, name: "index_music_tracks_on_release_medium_position"
  end
end
