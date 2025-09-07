require "test_helper"

class ImportListFromMusicbrainzSeriesJobTest < ActiveJob::TestCase
  def setup
    @list = lists(:music_albums_list)
  end

  test "perform calls ImportFromMusicbrainzSeries with correct list" do
    # Mock the import service
    DataImporters::Music::Lists::ImportFromMusicbrainzSeries
      .expects(:call)
      .with(list: @list)
      .returns({success: true, message: "Import completed"})

    # Run the job
    ImportListFromMusicbrainzSeriesJob.new.perform(@list.id)
  end
end
