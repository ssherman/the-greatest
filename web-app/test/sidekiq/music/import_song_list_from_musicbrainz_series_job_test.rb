# frozen_string_literal: true

require "test_helper"

class Music::ImportSongListFromMusicbrainzSeriesJobTest < ActiveSupport::TestCase
  def setup
    @list = lists(:music_songs_list)
    @list.update!(musicbrainz_series_id: "test-series-123")
  end

  test "perform calls the import service with the list" do
    DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries
      .expects(:call)
      .with(list: @list)
      .returns(success: true, message: "Imported songs")

    Music::ImportSongListFromMusicbrainzSeriesJob.new.perform(@list.id)
  end

  test "perform raises error when list not found" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Music::ImportSongListFromMusicbrainzSeriesJob.new.perform(999999)
    end
  end
end
