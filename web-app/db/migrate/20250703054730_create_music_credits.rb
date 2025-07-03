class CreateMusicCredits < ActiveRecord::Migration[8.0]
  def change
    create_table :music_credits do |t|
      t.references :artist, null: false, foreign_key: {to_table: :music_artists}
      t.references :creditable, polymorphic: true, null: false
      t.integer :role, null: false, default: 0
      t.integer :position

      t.timestamps
    end

    add_index :music_credits, [:creditable_type, :creditable_id]
    add_index :music_credits, [:artist_id, :role]
  end
end
