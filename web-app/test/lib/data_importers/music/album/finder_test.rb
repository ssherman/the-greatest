# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Album
      class FinderTest < ActiveSupport::TestCase
        def setup
          @finder = Finder.new
          @artist = music_artists(:pink_floyd)
          @query = ImportQuery.new(artist: @artist, title: "The Wall")
        end

        test "call returns existing album when found by MusicBrainz release group ID" do
          # Mock the search service to return The Wall's data
          search_service = mock
          search_service.expects(:search_by_artist_mbid_and_title)
            .with("83d91898-7763-47d7-b03b-b92132375c47", "The Wall")
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "f47f3fc2-c9e7-4fd6-b06b-5f2b2f7b8c8d",
                    "title" => "The Wall"
                  }
                ]
              }
            )

          @finder.stubs(:search_service).returns(search_service)

          # Mock finding by MusicBrainz ID to return existing album
          @finder.stubs(:find_by_musicbrainz_id).returns(music_albums(:dark_side_of_the_moon))

          result = @finder.call(query: @query)

          assert_equal music_albums(:dark_side_of_the_moon), result
        end

        test "call returns existing album when found by exact title match" do
          # Mock search service to return empty results
          search_service = mock
          search_service.expects(:search_by_artist_mbid_and_title)
            .with("83d91898-7763-47d7-b03b-b92132375c47", "The Dark Side of the Moon")
            .returns(
              success: true,
              data: {"release-groups" => []}
            )

          @finder.stubs(:search_service).returns(search_service)

          query = ImportQuery.new(artist: @artist, title: "The Dark Side of the Moon")
          result = @finder.call(query: query)

          assert_equal music_albums(:dark_side_of_the_moon), result
        end

        test "call returns nil when no album found by any method" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid_and_title)
            .with("83d91898-7763-47d7-b03b-b92132375c47", "Unknown Album")
            .returns(
              success: true,
              data: {"release-groups" => []}
            )

          @finder.stubs(:search_service).returns(search_service)

          unknown_query = ImportQuery.new(artist: @artist, title: "Unknown Album")
          result = @finder.call(query: unknown_query)

          assert_nil result
        end

        test "call handles MusicBrainz search errors gracefully" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid_and_title)
            .with("83d91898-7763-47d7-b03b-b92132375c47", "The Wall")
            .raises(StandardError, "Network error")

          @finder.stubs(:search_service).returns(search_service)

          Rails.logger.expects(:warn).with("MusicBrainz search failed in finder: Network error")

          # Should still fall back to title matching
          result = @finder.call(query: @query)

          assert_nil result # The Wall doesn't exist in fixtures
        end

        test "call returns nil when artist has no MusicBrainz ID" do
          artist_without_mbid = music_artists(:david_bowie) # Assuming this has no MusicBrainz ID
          query = ImportQuery.new(artist: artist_without_mbid, title: "Heroes")

          result = @finder.call(query: query)

          assert_nil result
        end

        test "call searches primary albums only when specified" do
          search_service = mock
          search_service.expects(:search_primary_albums_only)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "primary-album-id",
                    "title" => "The Wall"
                  }
                ]
              }
            )

          @finder.stubs(:search_service).returns(search_service)
          @finder.stubs(:find_by_musicbrainz_id).returns(nil)
          @finder.stubs(:find_by_title).returns(nil)

          query = ImportQuery.new(artist: @artist, title: "The Wall", primary_albums_only: true)
          result = @finder.call(query: query)

          assert_nil result # No matching album found
        end

        test "call searches all albums when primary_albums_only is false" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid_and_title)
            .with("83d91898-7763-47d7-b03b-b92132375c47", "The Wall")
            .returns(
              success: true,
              data: {"release-groups" => []}
            )

          @finder.stubs(:search_service).returns(search_service)

          query = ImportQuery.new(artist: @artist, title: "The Wall", primary_albums_only: false)
          result = @finder.call(query: query)

          assert_nil result
        end

        test "call searches for all albums when no title specified" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .returns(
              success: true,
              data: {"release-groups" => []}
            )

          @finder.stubs(:search_service).returns(search_service)

          query = ImportQuery.new(artist: @artist) # No title
          result = @finder.call(query: query)

          assert_nil result
        end

        test "call prioritizes MusicBrainz ID over title matching" do
          # Mock search to return a different album than what title matching would find
          search_service = mock
          search_service.expects(:search_by_artist_mbid_and_title)
            .with("83d91898-7763-47d7-b03b-b92132375c47", "Animals")
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "wish-you-were-here-id",
                    "title" => "Wish You Were Here"
                  }
                ]
              }
            )

          @finder.stubs(:search_service).returns(search_service)
          # Mock MusicBrainz ID search to return Wish You Were Here
          @finder.stubs(:find_by_musicbrainz_id).returns(music_albums(:wish_you_were_here))

          query = ImportQuery.new(artist: @artist, title: "Animals")
          result = @finder.call(query: query)

          # Should return Wish You Were Here (found by MBID) not Animals (found by title)
          assert_equal music_albums(:wish_you_were_here), result
        end
      end
    end
  end
end
