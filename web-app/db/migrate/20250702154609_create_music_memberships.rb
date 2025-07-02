class CreateMusicMemberships < ActiveRecord::Migration[8.0]
  def change
    create_table :music_memberships do |t|
      t.references :artist, null: false, foreign_key: {to_table: :music_artists}
      t.references :member, null: false, foreign_key: {to_table: :music_artists}
      t.date :joined_on
      t.date :left_on

      t.timestamps
    end

    add_index :music_memberships, [:artist_id, :member_id, :joined_on], unique: true, name: "index_music_memberships_on_artist_member_joined"
  end
end
