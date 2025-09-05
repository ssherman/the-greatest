require "test_helper"

class Music::ImportAlbumReleasesJobTest < ActiveSupport::TestCase
  def setup
    @album = music_albums(:dark_side_of_the_moon)
    @job = Music::ImportAlbumReleasesJob.new
  end

  test "perform with successful import logs success message" do
    # Mock successful import result
    successful_result = DataImporters::ImportResult.new(
      item: nil,
      provider_results: [],
      success: true
    )

    DataImporters::Music::Release::Importer.expects(:call)
      .with(album: @album)
      .returns(successful_result)

    Rails.logger.expects(:info)
      .with("Successfully imported releases for album #{@album.title}")

    @job.perform(@album.id)
  end

  test "perform with failed import logs error and raises exception" do
    # Mock failed import result with errors
    failed_result = DataImporters::ImportResult.new(
      item: nil,
      provider_results: [],
      success: false
    )

    # Mock the all_errors method
    failed_result.stubs(:all_errors).returns(["Network timeout", "Invalid data"])

    DataImporters::Music::Release::Importer.expects(:call)
      .with(album: @album)
      .returns(failed_result)

    Rails.logger.expects(:error)
      .with("Failed to import releases for album #{@album.title}: Network timeout, Invalid data")

    error = assert_raises(StandardError) do
      @job.perform(@album.id)
    end

    assert_equal "Release import failed: Network timeout, Invalid data", error.message
  end

  test "perform with invalid album id raises ActiveRecord::RecordNotFound" do
    invalid_id = 99999

    # Should not call the importer
    DataImporters::Music::Release::Importer.expects(:call).never

    assert_raises(ActiveRecord::RecordNotFound) do
      @job.perform(invalid_id)
    end
  end

  test "perform calls release importer with correct album" do
    # Mock successful import result
    successful_result = DataImporters::ImportResult.new(
      item: nil,
      provider_results: [],
      success: true
    )

    DataImporters::Music::Release::Importer.expects(:call)
      .with(album: @album)
      .returns(successful_result)

    Rails.logger.stubs(:info) # Don't care about logging in this test

    @job.perform(@album.id)
  end

  test "perform is idempotent - can be called multiple times safely" do
    # Mock successful import result
    successful_result = DataImporters::ImportResult.new(
      item: nil,
      provider_results: [],
      success: true
    )

    DataImporters::Music::Release::Importer.expects(:call)
      .with(album: @album)
      .twice
      .returns(successful_result)

    Rails.logger.stubs(:info) # Don't care about logging in this test

    # Call the job twice - should not cause issues
    @job.perform(@album.id)
    @job.perform(@album.id)
  end

  test "perform with different albums" do
    other_album = music_albums(:wish_you_were_here)

    # Mock successful import results for both albums
    successful_result = DataImporters::ImportResult.new(
      item: nil,
      provider_results: [],
      success: true
    )

    DataImporters::Music::Release::Importer.expects(:call)
      .with(album: @album)
      .returns(successful_result)

    DataImporters::Music::Release::Importer.expects(:call)
      .with(album: other_album)
      .returns(successful_result)

    Rails.logger.stubs(:info) # Don't care about logging in this test

    # Test with different albums
    @job.perform(@album.id)
    @job.perform(other_album.id)
  end

  test "job includes Sidekiq::Job module" do
    assert Music::ImportAlbumReleasesJob.included_modules.include?(Sidekiq::Job)
  end

  test "job uses default queue" do
    # Sidekiq jobs use 'default' queue unless otherwise specified
    # Since we didn't set sidekiq_options, it should use default
    assert_equal "default", Music::ImportAlbumReleasesJob.get_sidekiq_options["queue"]
  end
end
