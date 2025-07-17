class ChangeArtistDateFieldsToYears < ActiveRecord::Migration[8.0]
  def change
    # Remove old date fields
    remove_column :music_artists, :died_on, :date
    remove_column :music_artists, :formed_on, :date
    remove_column :music_artists, :disbanded_on, :date

    # Add new year fields
    add_column :music_artists, :year_died, :integer
    add_column :music_artists, :year_formed, :integer
    add_column :music_artists, :year_disbanded, :integer
  end
end
