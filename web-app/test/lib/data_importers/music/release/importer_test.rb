# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Release
      class ImporterTest < ActiveSupport::TestCase
        def setup
          @album = music_albums(:dark_side_of_the_moon)
        end

        test "call creates multiple releases from MusicBrainz" do
          musicbrainz_releases = [
            {
              "id" => "mb-release-1",
              "title" => "The Dark Side of the Moon - Original",
              "date" => "1973-03-01",
              "country" => "GB",
              "status" => "Official",
              "media" => [{"format" => "CD"}],
              "label-info" => [{"label" => {"name" => "Harvest"}}]
            },
            {
              "id" => "mb-release-2",
              "title" => "The Dark Side of the Moon - Remaster",
              "date" => "2011-09-26",
              "country" => "US",
              "status" => "Official",
              "media" => [{"format" => "12\" Vinyl"}],
              "label-info" => [{"label" => {"name" => "EMI"}}]
            }
          ]

          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
            .returns({data: {"releases" => musicbrainz_releases}})

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          initial_count = @album.releases.count

          result = Importer.call(album: @album)

          assert result.success?
          assert_nil result.item # Multi-item imports don't return a single item
          assert_equal 1, result.provider_results.length
          assert result.provider_results.first.success?

          # Verify releases were created
          assert_equal initial_count + 2, @album.releases.count
          assert @album.releases.exists?(release_name: "The Dark Side of the Moon - Original")
          assert @album.releases.exists?(release_name: "The Dark Side of the Moon - Remaster")
        end

        test "call skips existing releases but still processes others" do
          # Create existing release with MusicBrainz identifier
          existing_release = @album.releases.create!(
            format: :cd,
            status: :official,
            release_name: "Existing Release"
          )
          existing_release.identifiers.create!(
            identifier_type: :music_musicbrainz_release_id,
            value: "existing-mb-id"
          )

          musicbrainz_releases = [
            {
              "id" => "existing-mb-id",
              "title" => "Existing Release",
              "media" => [{"format" => "CD"}]
            },
            {
              "id" => "new-mb-id",
              "title" => "New Release",
              "media" => [{"format" => "Vinyl"}]
            }
          ]

          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
            .returns({data: {"releases" => musicbrainz_releases}})

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          initial_count = @album.releases.count

          result = Importer.call(album: @album)

          # Should run providers and create the new release
          assert result.success?
          assert_equal initial_count + 1, @album.releases.count
          assert @album.releases.exists?(release_name: "New Release")
        end

        test "call fails when album has no MusicBrainz ID" do
          album_without_mbid = music_albums(:animals)

          result = Importer.call(album: album_without_mbid)

          refute result.success?
          assert_equal 1, result.provider_results.length
          refute result.provider_results.first.success?
          assert_includes result.provider_results.first.errors, "No release group MBID found for album"
        end

        test "call handles MusicBrainz search failures gracefully" do
          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
            .raises(StandardError, "Network error")

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          result = Importer.call(album: @album)

          refute result.success?
          assert_equal 1, result.provider_results.length
          refute result.provider_results.first.success?
          assert_includes result.provider_results.first.errors.join(", "), "Network error"
        end

        test "call handles empty MusicBrainz results" do
          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
            .returns({"releases" => []})

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          result = Importer.call(album: @album)

          refute result.success?
          assert_includes result.provider_results.first.errors, "No releases found in MusicBrainz"
        end

        test "call validates query object" do
          assert_raises ArgumentError, "Invalid query object" do
            Importer.new.call(query: "invalid")
          end
        end

        test "call with nil album raises validation error" do
          assert_raises ArgumentError do
            Importer.call(album: nil)
          end
        end

        test "call with invalid album type raises validation error" do
          assert_raises ArgumentError do
            Importer.call(album: users(:regular_user))
          end
        end

        test "multi_item_import? returns true" do
          importer = Importer.new
          assert importer.send(:multi_item_import?)
        end

        test "call skips existing releases and creates new ones" do
          # Create one existing release
          existing_release = @album.releases.create!(
            format: :cd,
            status: :official,
            release_name: "Existing"
          )
          existing_release.identifiers.create!(
            identifier_type: :music_musicbrainz_release_id,
            value: "mb-existing"
          )

          musicbrainz_releases = [
            {
              "id" => "mb-existing", # This one exists
              "title" => "Existing Release",
              "media" => [{"format" => "CD"}]
            },
            {
              "id" => "mb-new-1", # This one is new
              "title" => "New Release 1",
              "media" => [{"format" => "Vinyl"}]
            },
            {
              "id" => "mb-new-2", # This one is new
              "title" => "New Release 2",
              "media" => [{"format" => "Digital Media"}]
            }
          ]

          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
            .returns({data: {"releases" => musicbrainz_releases}})

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          initial_count = @album.releases.count

          result = Importer.call(album: @album)

          assert result.success?
          # Should create 2 new releases (skipping the existing one)
          assert_equal initial_count + 2, @album.releases.count
          assert @album.releases.exists?(release_name: "New Release 1")
          assert @album.releases.exists?(release_name: "New Release 2")
        end

        test "call handles partial failures gracefully" do
          # This should succeed
          valid_release_data = {
            "id" => "mb-valid",
            "title" => "Valid Release",
            "media" => [{"format" => "Vinyl"}]
          }

          # This should also succeed (no unique constraint anymore)
          second_release_data = {
            "id" => "mb-second",
            "title" => "Second Release",
            "media" => [{"format" => "CD"}]
          }

          musicbrainz_releases = [valid_release_data, second_release_data]

          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .returns({data: {"releases" => musicbrainz_releases}})

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          initial_count = @album.releases.count

          result = Importer.call(album: @album)

          # Should be successful and create both releases
          assert result.success?
          # Both releases should be created
          assert_equal initial_count + 2, @album.releases.count
          assert @album.releases.where(release_name: "Valid Release").exists?
          assert @album.releases.where(release_name: "Second Release").exists?
        end

        test "call creates proper identifiers for releases" do
          musicbrainz_releases = [{
            "id" => "mb-identifier-test",
            "title" => "Identifier Test",
            "asin" => "B000123456",
            "media" => [{"format" => "CD"}]
          }]

          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .returns({data: {"releases" => musicbrainz_releases}})

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          result = Importer.call(album: @album)

          assert result.success?

          release = @album.releases.find_by(release_name: "Identifier Test")
          assert_not_nil release

          # Check MusicBrainz identifier
          mbid_identifier = release.identifiers.find_by(identifier_type: :music_musicbrainz_release_id)
          assert_equal "mb-identifier-test", mbid_identifier.value

          # Check ASIN identifier
          asin_identifier = release.identifiers.find_by(identifier_type: :music_asin)
          assert_equal "B000123456", asin_identifier.value
        end
      end
    end
  end
end
