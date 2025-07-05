class CreateMoviesMovies < ActiveRecord::Migration[8.0]
  def change
    create_table :movies_movies do |t|
      t.string :title, null: false
      t.string :slug, null: false
      t.text :description
      t.integer :release_year
      t.integer :runtime_minutes
      t.integer :rating

      t.timestamps
    end

    add_index :movies_movies, :slug, unique: true
    add_index :movies_movies, :release_year
    add_index :movies_movies, :rating
  end
end
