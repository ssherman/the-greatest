class AddExcludeFromRankingsToBooksAuthors < ActiveRecord::Migration[8.1]
  def up
    add_column :books_authors, :exclude_from_rankings, :boolean, null: false, default: false
    Books::Author.reset_column_information
    Books::Author.where(name: "Unknown").update_all(exclude_from_rankings: true)
  end

  def down
    remove_column :books_authors, :exclude_from_rankings
  end
end
