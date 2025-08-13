# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Album
      module Providers
        class MusicBrainzTest < ActiveSupport::TestCase
          def setup
            @provider = MusicBrainz.new
            @artist = music_artists(:pink_floyd)
            @query = ImportQuery.new(artist: @artist, title: "The Wall")
            @album = ::Music::Album.new(title: "The Wall", primary_artist: @artist)
          end

          test "populate returns success when album data found" do
            # Mock successful search result with The Wall data
            search_service = mock
            search_service.expects(:search_by_artist_mbid_and_title)
              .with("83d91898-7763-47d7-b03b-b92132375c47", "The Wall")
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => "the-wall-release-group-id",
                      "title" => "The Wall",
                      "first-release-date" => "1979-11-30"
                    }
                  ]
                }
              )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(@album, query: @query)

            assert result.success?
            assert_equal "The Wall", @album.title
            assert_equal @artist, @album.primary_artist
            assert_equal 1979, @album.release_year

            # Check identifier was built
            assert_equal 1, @album.identifiers.length
            musicbrainz_identifier = @album.identifiers.first
            assert_equal "music_musicbrainz_release_group_id", musicbrainz_identifier.identifier_type
            assert_equal "the-wall-release-group-id", musicbrainz_identifier.value

            expected_data_populated = [:title, :primary_artist, :musicbrainz_release_group_id, :release_year]
            assert_equal expected_data_populated, result.data_populated
          end

          test "populate handles album with no release date" do
            search_service = mock
            search_service.expects(:search_by_artist_mbid_and_title)
              .with("83d91898-7763-47d7-b03b-b92132375c47", "Unknown Album")
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => "unknown-album-id",
                      "title" => "Unknown Album"
                      # No first-release-date
                    }
                  ]
                }
              )

            @provider.stubs(:search_service).returns(search_service)

            query = ImportQuery.new(artist: @artist, title: "Unknown Album")
            album = ::Music::Album.new(title: "Unknown Album", primary_artist: @artist)

            result = @provider.populate(album, query: query)

            assert result.success?
            assert_equal "Unknown Album", album.title
            assert_nil album.release_year
            expected_data_populated = [:title, :primary_artist, :musicbrainz_release_group_id]
            assert_equal expected_data_populated, result.data_populated
          end

          test "populate returns failure when artist has no MusicBrainz ID" do
            artist_without_mbid = music_artists(:roger_waters) # This artist has no MusicBrainz ID
            query = ImportQuery.new(artist: artist_without_mbid, title: "Heroes")
            album = ::Music::Album.new(title: "Heroes", primary_artist: artist_without_mbid)

            result = @provider.populate(album, query: query)

            refute result.success?
            assert_equal ["Artist has no MusicBrainz ID"], result.errors
          end

          test "populate returns failure when search fails" do
            search_service = mock
            search_service.expects(:search_by_artist_mbid_and_title)
              .with("83d91898-7763-47d7-b03b-b92132375c47", "The Wall")
              .returns(
                success: false,
                errors: ["Network timeout"]
              )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(@album, query: @query)

            refute result.success?
            assert_equal ["Network timeout"], result.errors
          end

          test "populate returns failure when no albums found" do
            search_service = mock
            search_service.expects(:search_by_artist_mbid_and_title)
              .with("83d91898-7763-47d7-b03b-b92132375c47", "Nonexistent Album")
              .returns(
                success: true,
                data: {"release-groups" => []}
              )

            @provider.stubs(:search_service).returns(search_service)

            query = ImportQuery.new(artist: @artist, title: "Nonexistent Album")
            result = @provider.populate(@album, query: query)

            refute result.success?
            assert_equal ["No albums found"], result.errors
          end

          test "populate handles exceptions gracefully" do
            search_service = mock
            search_service.expects(:search_by_artist_mbid_and_title)
              .with("83d91898-7763-47d7-b03b-b92132375c47", "The Wall")
              .raises(StandardError, "Connection failed")

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(@album, query: @query)

            refute result.success?
            assert_includes result.errors.first, "MusicBrainz error: Connection failed"
          end

          test "populate searches primary albums only when specified" do
            search_service = mock
            # First, try primary albums search
            search_service.expects(:search_primary_albums_only)
              .with("83d91898-7763-47d7-b03b-b92132375c47")
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => "studio-album-id",
                      "title" => "Studio Album"
                    }
                  ]
                }
              )

            @provider.stubs(:search_service).returns(search_service)

            query = ImportQuery.new(artist: @artist, title: "Studio Album", primary_albums_only: true)
            album = ::Music::Album.new(title: "Studio Album", primary_artist: @artist)

            result = @provider.populate(album, query: query)

            assert result.success?
            assert_equal "Studio Album", album.title
          end

          test "populate falls back to general search when primary albums search finds no match" do
            search_service = mock
            # First, try primary albums search - finds nothing
            search_service.expects(:search_primary_albums_only)
              .with("83d91898-7763-47d7-b03b-b92132375c47")
              .returns(
                success: true,
                data: {"release-groups" => []}
              )
            # Then, fallback to general search
            search_service.expects(:search_by_artist_mbid_and_title)
              .with("83d91898-7763-47d7-b03b-b92132375c47", "Rare Album")
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => "rare-album-id",
                      "title" => "Rare Album"
                    }
                  ]
                }
              )

            @provider.stubs(:search_service).returns(search_service)

            query = ImportQuery.new(artist: @artist, title: "Rare Album", primary_albums_only: true)
            album = ::Music::Album.new(title: "Rare Album", primary_artist: @artist)

            result = @provider.populate(album, query: query)

            assert result.success?
            assert_equal "Rare Album", album.title
          end

          test "populate searches all albums when no title specified" do
            search_service = mock
            search_service.expects(:search_by_artist_mbid)
              .with("83d91898-7763-47d7-b03b-b92132375c47")
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => "first-album-id",
                      "title" => "First Album"
                    }
                  ]
                }
              )

            @provider.stubs(:search_service).returns(search_service)

            query = ImportQuery.new(artist: @artist) # No title
            album = ::Music::Album.new(primary_artist: @artist)

            result = @provider.populate(album, query: query)

            assert result.success?
            assert_equal "First Album", album.title
          end

          test "populate does not overwrite existing album title when blank in search result" do
            search_service = mock
            search_service.expects(:search_by_artist_mbid_and_title)
              .with("83d91898-7763-47d7-b03b-b92132375c47", "The Wall")
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => "the-wall-id",
                      "title" => "", # Blank title in MusicBrainz result
                      "first-release-date" => "1979"
                    }
                  ]
                }
              )

            @provider.stubs(:search_service).returns(search_service)

            # Album starts with a title
            @album.title = "The Wall"

            result = @provider.populate(@album, query: @query)

            assert result.success?
            assert_equal "The Wall", @album.title # Should preserve original title
          end

          test "populate handles partial release date (year only)" do
            search_service = mock
            search_service.expects(:search_by_artist_mbid_and_title)
              .with("83d91898-7763-47d7-b03b-b92132375c47", "Album 1979")
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => "album-1979-id",
                      "title" => "Album 1979",
                      "first-release-date" => "1979" # Just year
                    }
                  ]
                }
              )

            @provider.stubs(:search_service).returns(search_service)

            query = ImportQuery.new(artist: @artist, title: "Album 1979")
            album = ::Music::Album.new(title: "Album 1979", primary_artist: @artist)

            result = @provider.populate(album, query: query)

            assert result.success?
            assert_equal 1979, album.release_year
          end

          # NEW TEST: verify genre categories created and associated for albums
          test "populate creates top 5 genre categories for albums and does not create location categories" do
            persisted_album = music_albums(:animals)

            search_service = mock
            search_service.expects(:search_by_artist_mbid_and_title)
              .with("83d91898-7763-47d7-b03b-b92132375c47", "The Wall")
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => "the-wall-release-group-id",
                      "title" => "The Wall",
                      "first-release-date" => "1979-11-30",
                      "tags" => [
                        {"count" => 25, "name" => "progressive rock"},
                        {"count" => 19, "name" => "art rock"},
                        {"count" => 9, "name" => "concept album"},
                        {"count" => 8, "name" => "psychedelic rock"},
                        {"count" => 6, "name" => "british"},
                        {"count" => 0, "name" => "downtempo"}
                      ]
                    }
                  ]
                }
              )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(persisted_album, query: @query)
            assert result.success?

            persisted_album.reload

            names = persisted_album.categories.pluck(:name)
            assert_includes names, "Progressive Rock"
            assert_includes names, "Art Rock"
            assert_includes names, "Concept Album"
            assert_includes names, "Psychedelic Rock"
            assert_includes names, "British"
            refute_includes names, "Downtempo"

            # Ensure no location categories were created/associated for album
            assert_equal 0, persisted_album.categories.where(category_type: "location").count
          end
        end
      end
    end
  end
end
