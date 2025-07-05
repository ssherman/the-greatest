class CreateMoviesPeople < ActiveRecord::Migration[8.0]
  def change
    create_table :movies_people do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :description
      t.date :born_on
      t.date :died_on
      t.string :country, limit: 2
      t.integer :gender

      t.timestamps
    end

    add_index :movies_people, :slug, unique: true
    add_index :movies_people, :gender
  end
end
