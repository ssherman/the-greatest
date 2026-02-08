class CreateGamesGameCompanies < ActiveRecord::Migration[8.1]
  def change
    create_table :games_game_companies do |t|
      t.references :game, null: false, foreign_key: {to_table: :games_games}
      t.references :company, null: false, foreign_key: {to_table: :games_companies}
      t.boolean :developer, null: false, default: false
      t.boolean :publisher, null: false, default: false

      t.timestamps
    end
    add_index :games_game_companies, [:game_id, :company_id], unique: true, name: "index_games_game_companies_on_game_and_company"
    add_index :games_game_companies, :developer
    add_index :games_game_companies, :publisher
  end
end
