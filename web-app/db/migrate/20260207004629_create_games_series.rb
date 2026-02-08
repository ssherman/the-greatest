class CreateGamesSeries < ActiveRecord::Migration[8.1]
  def change
    create_table :games_series do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description

      t.timestamps
    end
    add_index :games_series, :name
    add_index :games_series, :slug, unique: true
  end
end
