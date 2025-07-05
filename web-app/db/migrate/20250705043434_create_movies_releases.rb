class CreateMoviesReleases < ActiveRecord::Migration[8.0]
  def change
    create_table :movies_releases do |t|
      t.bigint :movie_id, null: false
      t.string :release_name
      t.integer :release_format, null: false, default: 0
      t.integer :runtime_minutes
      t.date :release_date
      t.jsonb :metadata
      t.boolean :is_primary, null: false, default: false

      t.timestamps
    end

    add_foreign_key :movies_releases, :movies_movies, column: :movie_id
    add_index :movies_releases, [:movie_id, :release_name, :release_format], unique: true, name: "index_movies_releases_on_movie_and_name_and_format"
    add_index :movies_releases, :is_primary
    add_index :movies_releases, :movie_id
    add_index :movies_releases, :release_date
    add_index :movies_releases, :release_format
  end
end
