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
            @album = ::Music::Album.new(title: "The Wall")
            @album.album_artists.build(artist: @artist, position: 1)
            # Stub the cover art download job since we're testing album provider
            ::Music::CoverArtDownloadJob.stubs(:perform_async)
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
            assert @album.album_artists.any? { |aa| aa.artist == @artist }, "Expected album to have artist association"
            assert_equal 1979, @album.release_year

            # Check identifier was built
            assert_equal 1, @album.identifiers.length
            musicbrainz_identifier = @album.identifiers.first
            assert_equal "music_musicbrainz_release_group_id", musicbrainz_identifier.identifier_type
            assert_equal "the-wall-release-group-id", musicbrainz_identifier.value

            expected_data_populated = [:title, :artists, :musicbrainz_release_group_id, :release_year]
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
            album = ::Music::Album.new(title: "Unknown Album")
            album.album_artists.build(artist: @artist, position: 1)

            result = @provider.populate(album, query: query)

            assert result.success?
            assert_equal "Unknown Album", album.title
            assert_nil album.release_year
            expected_data_populated = [:title, :artists, :musicbrainz_release_group_id]
            assert_equal expected_data_populated, result.data_populated
          end

          test "populate returns failure when artist has no MusicBrainz ID" do
            artist_without_mbid = music_artists(:roger_waters) # This artist has no MusicBrainz ID
            query = ImportQuery.new(artist: artist_without_mbid, title: "Heroes")
            album = ::Music::Album.new(title: "Heroes")
            album.album_artists.build(artist: artist_without_mbid, position: 1)

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
            album = ::Music::Album.new(title: "Studio Album")
            album.album_artists.build(artist: @artist, position: 1)

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
            album = ::Music::Album.new(title: "Rare Album")
            album.album_artists.build(artist: @artist, position: 1)

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
            album = ::Music::Album.new
            album.album_artists.build(artist: @artist, position: 1)

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
            album = ::Music::Album.new(title: "Album 1979")
            album.album_artists.build(artist: @artist, position: 1)

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

          # Tests for new MusicBrainz Release Group ID lookup functionality
          test "populate with release_group_musicbrainz_id uses lookup API" do
            mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
            query = ImportQuery.new(release_group_musicbrainz_id: mbid)
            album = ::Music::Album.new

            # Mock lookup result
            search_service = mock
            search_service.expects(:lookup_by_release_group_mbid)
              .with(mbid)
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => mbid,
                      "title" => "Piñata",
                      "first-release-date" => "2014-03-18",
                      "artist-credit" => [
                        {
                          "artist" => {
                            "id" => "artist-mbid-1",
                            "name" => "Test Artist"
                          }
                        }
                      ],
                      "genres" => [
                        {"name" => "hip hop", "count" => 4}
                      ]
                    }
                  ]
                }
              )

            # Mock artist import - return ImportResult object (simulates new artist import)
            test_artist = music_artists(:david_bowie)
            import_result = DataImporters::ImportResult.new(
              item: test_artist,
              provider_results: [],
              success: true
            )
            DataImporters::Music::Artist::Importer.stubs(:call)
              .with(musicbrainz_id: "artist-mbid-1")
              .returns(import_result)

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(album, query: query)

            assert result.success?
            assert_equal "Piñata", album.title
            assert_equal 2014, album.release_year

            # Save album to persist associations for testing
            album.save!

            # Check artist was associated
            assert_includes album.artists, test_artist

            # Check identifier was built
            identifier = album.identifiers.find { |id| id.identifier_type == "music_musicbrainz_release_group_id" }
            assert_equal mbid, identifier.value
          end

          test "populate with release_group_musicbrainz_id handles multiple artists" do
            mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
            query = ImportQuery.new(release_group_musicbrainz_id: mbid)
            album = ::Music::Album.new

            # Mock lookup result with multiple artists
            search_service = mock
            search_service.expects(:lookup_by_release_group_mbid)
              .with(mbid)
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => mbid,
                      "title" => "Collaboration Album",
                      "artist-credit" => [
                        {
                          "artist" => {
                            "id" => "artist-mbid-1",
                            "name" => "Artist One"
                          }
                        },
                        {
                          "artist" => {
                            "id" => "artist-mbid-2",
                            "name" => "Artist Two"
                          }
                        }
                      ]
                    }
                  ]
                }
              )

            # Mock artist imports - return ImportResult objects (simulates new artist imports)
            artist_one = music_artists(:david_bowie)
            artist_two = music_artists(:the_beatles)

            import_result_one = DataImporters::ImportResult.new(
              item: artist_one,
              provider_results: [],
              success: true
            )
            import_result_two = DataImporters::ImportResult.new(
              item: artist_two,
              provider_results: [],
              success: true
            )

            DataImporters::Music::Artist::Importer.stubs(:call)
              .with(musicbrainz_id: "artist-mbid-1")
              .returns(import_result_one)

            DataImporters::Music::Artist::Importer.stubs(:call)
              .with(musicbrainz_id: "artist-mbid-2")
              .returns(import_result_two)

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(album, query: query)

            assert result.success?
            assert_equal "Collaboration Album", album.title

            # Save album to persist associations for testing
            album.save!

            # Check both artists were associated with correct positions
            assert_includes album.artists, artist_one
            assert_includes album.artists, artist_two

            artist_positions = album.album_artists.map { |aa| [aa.artist, aa.position] }.to_h
            assert_equal 1, artist_positions[artist_one]
            assert_equal 2, artist_positions[artist_two]
          end

          test "populate with release_group_musicbrainz_id fails when no artists imported" do
            mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
            query = ImportQuery.new(release_group_musicbrainz_id: mbid)
            album = ::Music::Album.new

            # Mock lookup result
            search_service = mock
            search_service.expects(:lookup_by_release_group_mbid)
              .with(mbid)
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => mbid,
                      "title" => "Test Album",
                      "artist-credit" => [
                        {
                          "artist" => {
                            "id" => "unknown-artist-mbid",
                            "name" => "Unknown Artist"
                          }
                        }
                      ]
                    }
                  ]
                }
              )

            # Mock artist import failure
            DataImporters::Music::Artist::Importer.stubs(:call)
              .with(musicbrainz_id: "unknown-artist-mbid")
              .raises(StandardError, "Artist not found")

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(album, query: query)

            refute result.success?
            assert_includes result.errors, "No valid artists found"
          end

          test "populate with release_group_musicbrainz_id handles lookup failures" do
            mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
            query = ImportQuery.new(release_group_musicbrainz_id: mbid)
            album = ::Music::Album.new

            # Mock lookup failure
            search_service = mock
            search_service.expects(:lookup_by_release_group_mbid)
              .with(mbid)
              .returns(
                success: false,
                errors: ["Release group not found"]
              )

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(album, query: query)

            refute result.success?
            assert_includes result.errors, "Release group not found"
          end

          test "populate with release_group_musicbrainz_id processes genres from both tags and genres" do
            # Stub the release import job since we're testing MusicBrainz data population
            ::Music::ImportAlbumReleasesJob.stubs(:perform_async)

            mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"
            query = ImportQuery.new(release_group_musicbrainz_id: mbid)
            album = ::Music::Album.create!(title: "Test Album", slug: "test-album-lookup-genres")

            # Mock lookup result with both tags and genres
            search_service = mock
            search_service.expects(:lookup_by_release_group_mbid)
              .with(mbid)
              .returns(
                success: true,
                data: {
                  "release-groups" => [
                    {
                      "id" => mbid,
                      "title" => "Genre Test Album",
                      "artist-credit" => [
                        {
                          "artist" => {
                            "id" => "artist-mbid-1",
                            "name" => "Test Artist"
                          }
                        }
                      ],
                      "tags" => [
                        {"name" => "electronic", "count" => 10},
                        {"name" => "ambient", "count" => 5}
                      ],
                      "genres" => [
                        {"name" => "hip hop", "count" => 15},
                        {"name" => "rap", "count" => 8}
                      ]
                    }
                  ]
                }
              )

            # Mock artist import - return ImportResult (simulates new artist import)
            test_artist = music_artists(:david_bowie)
            import_result = DataImporters::ImportResult.new(
              item: test_artist,
              provider_results: [],
              success: true
            )
            DataImporters::Music::Artist::Importer.stubs(:call)
              .returns(import_result)

            @provider.stubs(:search_service).returns(search_service)

            result = @provider.populate(album, query: query)

            assert result.success?

            album.reload
            category_names = album.categories.where(category_type: "genre").pluck(:name)

            # Should include genres from both "tags" and "genres" fields
            assert_includes category_names, "Electronic"
            assert_includes category_names, "Ambient"
            assert_includes category_names, "Hip Hop"
            assert_includes category_names, "Rap"
          end
        end
      end
    end
  end
end
