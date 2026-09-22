class AddLowerTitleAndNameIndexesForFinders < ActiveRecord::Migration[8.1]
  # CONCURRENTLY cannot run inside a transaction. books_books holds ~157k
  # rows and music/games are live on this database, so a plain CREATE INDEX
  # would hold a SHARE lock on each table for the build.
  disable_ddl_transaction!

  # The finders' exact source queries LOWER(title) = ? (or LOWER(name) = ?).
  # No table but games_companies has any index on the column, and none has
  # one on the lowercased expression, so today each lookup is a sequential
  # scan. The expression is written to match what the planner records for a
  # varchar column: lower((title)::text).
  INDEXES = [
    [:books_books, "LOWER(title)", "index_books_books_on_lower_title"],
    [:books_authors, "LOWER(name)", "index_books_authors_on_lower_name"],
    [:music_albums, "LOWER(title)", "index_music_albums_on_lower_title"],
    [:music_artists, "LOWER(name)", "index_music_artists_on_lower_name"],
    [:music_songs, "LOWER(title)", "index_music_songs_on_lower_title"],
    [:games_games, "LOWER(title)", "index_games_games_on_lower_title"],
    [:games_companies, "LOWER(name)", "index_games_companies_on_lower_name"]
  ].freeze

  def up
    INDEXES.each do |table, expression, name|
      add_index table, expression, name: name, algorithm: :concurrently, if_not_exists: true
    end
  end

  def down
    INDEXES.each do |table, _expression, name|
      remove_index table, name: name, algorithm: :concurrently, if_exists: true
    end
  end
end
