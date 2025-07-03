class CreateMusicSongs < ActiveRecord::Migration[8.0]
  def change
    create_table :music_songs do |t|
      t.string :title, null: false
      t.string :slug, null: false
      t.text :description
      t.integer :duration_secs
      t.integer :release_year
      t.string :isrc, limit: 12
      t.text :lyrics

      t.timestamps
    end

    add_index :music_songs, :slug, unique: true
    add_index :music_songs, :isrc, unique: true, where: "isrc IS NOT NULL"
  end
end
