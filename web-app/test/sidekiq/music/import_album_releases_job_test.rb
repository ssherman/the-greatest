require "test_helper"

class Music::ImportAlbumReleasesJobTest < ActiveSupport::TestCase
  def setup
    @album = music_albums(:dark_side_of_the_moon)
    @job = Music::ImportAlbumReleasesJob.new
  end

  test "perform calls release importer with correct album" do
    successful_result = DataImporters::ImportResult.new(
      item: nil,
      provider_results: [],
      success: true
    )

    DataImporters::Music::Release::Importer.expects(:call)
      .with(album: @album)
      .returns(successful_result)

    Rails.logger.stubs(:info)

    @job.perform(@album.id)
  end

  test "perform raises error on failed import" do
    failed_result = DataImporters::ImportResult.new(
      item: nil,
      provider_results: [],
      success: false
    )
    failed_result.stubs(:all_errors).returns(["Import failed"])

    DataImporters::Music::Release::Importer.expects(:call)
      .returns(failed_result)

    Rails.logger.stubs(:error)

    assert_raises(StandardError) do
      @job.perform(@album.id)
    end
  end
end
