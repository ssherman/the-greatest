class CreateMusicSongRelationships < ActiveRecord::Migration[8.0]
  def change
    create_table :music_song_relationships do |t|
      t.references :song, null: false, foreign_key: {to_table: :music_songs}
      t.references :related_song, null: false, foreign_key: {to_table: :music_songs}
      t.integer :relation_type, null: false, default: 0
      t.references :source_release, foreign_key: {to_table: :music_releases}

      t.timestamps
    end

    add_index :music_song_relationships, [:song_id, :related_song_id, :relation_type], unique: true, name: "index_music_song_relationships_on_song_related_type"
  end
end
