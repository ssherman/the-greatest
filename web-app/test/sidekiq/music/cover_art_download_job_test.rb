# frozen_string_literal: true

require "test_helper"

module Music
  class CoverArtDownloadJobTest < ActiveSupport::TestCase
    def setup
      @album = music_albums(:dark_side_of_the_moon)
      @job = CoverArtDownloadJob.new
    end

    test "perform skips download when album already has primary image" do
      # Create an actual primary image to test the logic
      @album.images.create!(primary: true) do |image|
        image.file.attach(
          io: StringIO.new("fake image data"),
          filename: "test.jpg",
          content_type: "image/jpeg"
        )
      end

      # Should not make any HTTP requests
      assert_not_requested :get, /coverartarchive\.org/

      @job.perform(@album.id)
    end

    test "perform skips download when album has no MusicBrainz ID" do
      # Remove any MusicBrainz identifiers
      @album.identifiers.where(identifier_type: :music_musicbrainz_release_group_id).destroy_all
      @album.images.where(primary: true).destroy_all

      # Should not make any HTTP requests
      assert_not_requested :get, /coverartarchive\.org/

      @job.perform(@album.id)
    end

    test "perform attempts download when conditions are met" do
      # Ensure album has no primary image
      @album.images.where(primary: true).destroy_all

      # Get the existing MusicBrainz ID from the fixture
      identifier = @album.identifiers.find_by(identifier_type: :music_musicbrainz_release_group_id)
      musicbrainz_id = identifier&.value || "f5093c06-23e3-404f-afe0-f9df359d6e68"

      # Stub the HTTP request to return a mock image response
      stub_request(:get, "https://coverartarchive.org/release-group/#{musicbrainz_id}/front")
        .to_return(status: 404, body: "Not found")

      # Job should handle the 404 gracefully
      assert_nothing_raised do
        @job.perform(@album.id)
      end

      # Verify the request was made
      assert_requested :get, "https://coverartarchive.org/release-group/#{musicbrainz_id}/front"
    end

    test "perform creates image when download succeeds" do
      # Ensure album has no primary image
      @album.images.where(primary: true).destroy_all

      # Get the existing MusicBrainz ID from the fixture
      identifier = @album.identifiers.find_by(identifier_type: :music_musicbrainz_release_group_id)
      musicbrainz_id = identifier&.value || "f5093c06-23e3-404f-afe0-f9df359d6e68"

      # Stub the HTTP request to return a successful image response
      stub_request(:get, "https://coverartarchive.org/release-group/#{musicbrainz_id}/front")
        .to_return(
          status: 200,
          body: "fake image data",
          headers: {"Content-Type" => "image/jpeg"}
        )

      @job.perform(@album.id)

      # Verify the request was made
      assert_requested :get, "https://coverartarchive.org/release-group/#{musicbrainz_id}/front"

      # Verify image was created
      assert @album.images.where(primary: true).exists?
    end

    test "perform handles download errors gracefully" do
      # Ensure album has no primary image
      @album.images.where(primary: true).destroy_all

      # Get the existing MusicBrainz ID from the fixture
      identifier = @album.identifiers.find_by(identifier_type: :music_musicbrainz_release_group_id)
      musicbrainz_id = identifier&.value || "f5093c06-23e3-404f-afe0-f9df359d6e68"

      # Stub the HTTP request to return an error
      stub_request(:get, "https://coverartarchive.org/release-group/#{musicbrainz_id}/front")
        .to_raise(StandardError.new("Network error"))

      # Job should not raise an error, it should handle it gracefully
      assert_nothing_raised do
        @job.perform(@album.id)
      end

      # Verify the request was attempted
      assert_requested :get, "https://coverartarchive.org/release-group/#{musicbrainz_id}/front"

      # Ensure no image was created since download failed
      refute @album.images.where(primary: true).exists?
    end

    test "job is configured for serial queue" do
      assert_equal :serial, CoverArtDownloadJob.get_sidekiq_options["queue"]
    end

    test "job includes Sidekiq::Job" do
      assert CoverArtDownloadJob.include?(Sidekiq::Job)
    end
  end
end
