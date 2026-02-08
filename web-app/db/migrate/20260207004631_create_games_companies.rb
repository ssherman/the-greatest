class CreateGamesCompanies < ActiveRecord::Migration[8.1]
  def change
    create_table :games_companies do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.string :country, limit: 2
      t.integer :year_founded

      t.timestamps
    end
    add_index :games_companies, :name
    add_index :games_companies, :slug, unique: true
  end
end
