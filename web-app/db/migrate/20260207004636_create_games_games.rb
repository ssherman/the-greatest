class CreateGamesGames < ActiveRecord::Migration[8.1]
  def change
    create_table :games_games do |t|
      t.string :title, null: false
      t.string :slug, null: false
      t.text :description
      t.integer :release_year
      t.integer :game_type, null: false, default: 0
      t.references :parent_game, foreign_key: {to_table: :games_games}
      t.references :series, foreign_key: {to_table: :games_series}

      t.timestamps
    end
    add_index :games_games, :slug, unique: true
    add_index :games_games, :release_year
    add_index :games_games, :game_type
  end
end
