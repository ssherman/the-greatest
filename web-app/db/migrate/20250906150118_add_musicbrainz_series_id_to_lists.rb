class AddMusicbrainzSeriesIdToLists < ActiveRecord::Migration[8.0]
  def change
    add_column :lists, :musicbrainz_series_id, :string
  end
end
