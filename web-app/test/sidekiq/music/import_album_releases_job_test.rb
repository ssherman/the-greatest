require "test_helper"

class Music::ImportAlbumReleasesJobTest < ActiveSupport::TestCase
  def setup
    @album = music_albums(:dark_side_of_the_moon)
    @job = Music::ImportAlbumReleasesJob.new
  end

  test "perform calls release importer with correct album" do
    # Add MusicBrainz identifier so job doesn't skip
    @album.identifiers.create!(
      identifier_type: :music_musicbrainz_release_group_id,
      value: "test-mbid"
    )

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
    # Add MusicBrainz identifier so job doesn't skip
    @album.identifiers.create!(
      identifier_type: :music_musicbrainz_release_group_id,
      value: "test-mbid"
    )

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

  test "perform raises error when album has no MusicBrainz release group ID" do
    # Use animals album which has no MusicBrainz release group identifier
    animals_album = music_albums(:animals)

    # Should not call the importer
    DataImporters::Music::Release::Importer.expects(:call).never

    assert_raises(StandardError) do
      @job.perform(animals_album.id)
    end
  end
end
