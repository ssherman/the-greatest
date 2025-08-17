# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Release
      class FinderTest < ActiveSupport::TestCase
        def setup
          @album = music_albums(:dark_side_of_the_moon)
          @query = ImportQuery.new(album: @album)
          @finder = Finder.new
        end

        test "call returns nil when album has no release group MBID" do
          album_without_mbid = music_albums(:animals) # This album has no MusicBrainz ID
          query = ImportQuery.new(album: album_without_mbid)

          result = @finder.call(query: query)

          assert_nil result
        end

        test "call returns nil when MusicBrainz search fails" do
          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
            .raises(StandardError, "Network error")

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          result = @finder.call(query: @query)

          assert_nil result
        end

        test "call returns nil when MusicBrainz returns no releases" do
          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
            .returns({"releases" => []})

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          result = @finder.call(query: @query)

          assert_nil result
        end

        test "call returns existing release when found by MusicBrainz ID" do
          # Create a release with a MusicBrainz identifier
          release = music_releases(:dark_side_original)
          release.identifiers.create!(
            identifier_type: :music_musicbrainz_release_id,
            value: "mb-release-123"
          )

          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
            .returns({
              data: {
                "releases" => [
                  {"id" => "mb-release-123"},
                  {"id" => "mb-release-456"}
                ]
              }
            })

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          result = @finder.call(query: @query)

          assert_equal release, result
        end

        test "call returns nil when no existing releases match MusicBrainz IDs" do
          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
            .returns({
              data: {
                "releases" => [
                  {"id" => "unknown-release-123"},
                  {"id" => "unknown-release-456"}
                ]
              }
            })

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          result = @finder.call(query: @query)

          assert_nil result
        end

        test "call returns first matching release when multiple exist" do
          # Create two releases with MusicBrainz identifiers
          release1 = music_releases(:dark_side_original)
          release1.identifiers.create!(
            identifier_type: :music_musicbrainz_release_id,
            value: "mb-release-123"
          )

          release2 = music_releases(:dark_side_remaster)
          release2.identifiers.create!(
            identifier_type: :music_musicbrainz_release_id,
            value: "mb-release-456"
          )

          search_service = mock
          search_service.expects(:search_by_release_group_mbid)
            .with("f5093c06-23e3-404f-afe0-f9df359d6e68")
            .returns({
              data: {
                "releases" => [
                  {"id" => "mb-release-123"},
                  {"id" => "mb-release-456"}
                ]
              }
            })

          ::Music::Musicbrainz::Search::ReleaseSearch.stubs(:new).returns(search_service)

          result = @finder.call(query: @query)

          # Should return the first one found (order may vary)
          assert_includes [release1, release2], result
        end

        private

        def create_release_with_mbid(album, mbid)
          release = ::Music::Release.create!(
            album: album,
            format: :cd,
            status: :official,
            release_name: "Test Release"
          )
          release.identifiers.create!(
            identifier_type: :music_musicbrainz_release_id,
            value: mbid
          )
          release
        end
      end
    end
  end
end
