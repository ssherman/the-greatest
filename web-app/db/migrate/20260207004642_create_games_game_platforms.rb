class CreateGamesGamePlatforms < ActiveRecord::Migration[8.1]
  def change
    create_table :games_game_platforms do |t|
      t.references :game, null: false, foreign_key: {to_table: :games_games}
      t.references :platform, null: false, foreign_key: {to_table: :games_platforms}

      t.timestamps
    end
    add_index :games_game_platforms, [:game_id, :platform_id], unique: true, name: "index_games_game_platforms_on_game_and_platform"
  end
end
