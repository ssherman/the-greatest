class CreateGamesPlatforms < ActiveRecord::Migration[8.1]
  def change
    create_table :games_platforms do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :abbreviation
      t.integer :platform_family

      t.timestamps
    end
    add_index :games_platforms, :slug, unique: true
    add_index :games_platforms, :platform_family
  end
end
