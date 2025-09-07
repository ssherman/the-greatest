# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Album
      class ImporterTest < ActiveSupport::TestCase
        def setup
          @artist = music_artists(:pink_floyd)
        end

        test "call with artist and title creates and imports new album" do
          # Mock MusicBrainz search to return no existing album (called twice - finder + provider)
          search_service = mock
          search_service.expects(:search_by_artist_mbid_and_title)
            .with("83d91898-7763-47d7-b03b-b92132375c47", "The Wall")
            .twice
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "the-wall-mbid",
                    "title" => "The Wall",
                    "first-release-date" => "1979-11-30"
                  }
                ]
              }
            )

          # Stub the search service creation
          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(artist: @artist, title: "The Wall")

          assert result.success?
          assert_instance_of ::Music::Album, result.item
          assert_equal "The Wall", result.item.title
          assert_includes result.item.artists, @artist
          assert result.item.persisted?
          assert_equal 1979, result.item.release_year
        end

        test "call returns existing album when found" do
          # Use existing fixture album
          existing_album = music_albums(:dark_side_of_the_moon)

          # Mock the finder to return existing album
          finder = mock
          finder.expects(:call).returns(existing_album)
          Finder.stubs(:new).returns(finder)

          result = Importer.call(artist: @artist, title: "The Dark Side of the Moon")

          assert_instance_of DataImporters::ImportResult, result
          assert result.success?
          assert_equal existing_album, result.item
        end

        test "call handles MusicBrainz failures gracefully" do
          # Mock MusicBrainz search to fail (called twice - finder + provider)
          search_service = mock
          search_service.expects(:search_by_artist_mbid_and_title)
            .with("83d91898-7763-47d7-b03b-b92132375c47", "Test Album")
            .twice
            .raises(StandardError, "Network error")

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          Rails.logger.expects(:warn).with("MusicBrainz search failed in finder: Network error").once

          result = Importer.call(artist: @artist, title: "Test Album")

          # Should fail because both finder and provider failed
          refute result.success?
        end

        test "call passes options to query" do
          search_service = mock
          search_service.expects(:search_primary_albums_only)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .twice
            .returns(
              success: true,
              data: {"release-groups" => []}
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(artist: @artist, primary_albums_only: true)

          # Should fail because provider found no albums
          refute result.success?
        end

        test "call creates album when no MusicBrainz results found" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .twice
            .returns(
              success: true,
              data: {"release-groups" => []}
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(artist: @artist)

          # Should fail because provider found no albums
          refute result.success?
        end

        test "call imports all albums when no title specified" do
          search_service = mock
          search_service.expects(:search_by_artist_mbid)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .twice
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "first-album-mbid",
                    "title" => "First Album",
                    "first-release-date" => "1970"
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(artist: @artist)

          assert result.success?
          assert_equal "First Album", result.item.title
          assert_equal 1970, result.item.release_year
        end

        test "call fails when artist has no MusicBrainz ID" do
          artist_without_mbid = music_artists(:roger_waters) # This artist has no MusicBrainz ID

          result = Importer.call(artist: artist_without_mbid, title: "Heroes")

          refute result.success?
          assert_includes result.all_errors.join(", "), "Artist has no MusicBrainz ID"
        end

        test "call handles primary albums only search" do
          search_service = mock
          search_service.expects(:search_primary_albums_only)
            .with("83d91898-7763-47d7-b03b-b92132375c47")
            .twice
            .returns(
              success: true,
              data: {
                "release-groups" => [
                  {
                    "id" => "studio-album-mbid",
                    "title" => "Studio Album",
                    "first-release-date" => "1975"
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(artist: @artist, primary_albums_only: true)

          assert result.success?
          assert_equal "Studio Album", result.item.title
        end

        # Tests for new MusicBrainz Release Group ID functionality
        test "call with release_group_musicbrainz_id imports new album with artist lookup" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"

          # Mock ReleaseGroupSearch lookup
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
                        "name" => "Freddie Gibbs",
                        "joinphrase" => " & ",
                        "artist" => {
                          "id" => "21645c31-fe1c-45a4-955c-3e172b12c3f9",
                          "name" => "Freddie Gibbs"
                        }
                      },
                      {
                        "name" => "Madlib",
                        "joinphrase" => "",
                        "artist" => {
                          "id" => "ea9078ef-20ca-4506-81ea-2ae5fe3a42e8",
                          "name" => "Madlib"
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

          # Mock Artist Importer for both artists - return ImportResult objects (simulates new artist imports)
          david_bowie = music_artists(:david_bowie)
          the_beatles = music_artists(:the_beatles)

          david_bowie_result = DataImporters::ImportResult.new(
            item: david_bowie,
            provider_results: [],
            success: true
          )
          the_beatles_result = DataImporters::ImportResult.new(
            item: the_beatles,
            provider_results: [],
            success: true
          )

          DataImporters::Music::Artist::Importer.stubs(:call)
            .with(musicbrainz_id: "21645c31-fe1c-45a4-955c-3e172b12c3f9")
            .returns(david_bowie_result)

          DataImporters::Music::Artist::Importer.stubs(:call)
            .with(musicbrainz_id: "ea9078ef-20ca-4506-81ea-2ae5fe3a42e8")
            .returns(the_beatles_result)

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(release_group_musicbrainz_id: mbid)

          assert result.success?
          assert_instance_of ::Music::Album, result.item
          assert_equal "Piñata", result.item.title
          assert result.item.persisted?
          assert_equal 2014, result.item.release_year

          # Check that both artists are associated
          artist_names = result.item.artists.pluck(:name).sort
          assert_includes artist_names, "David Bowie"
          assert_includes artist_names, "The Beatles"

          # Check that MusicBrainz identifier is created
          identifier = result.item.identifiers.find_by(identifier_type: :music_musicbrainz_release_group_id)
          assert_equal mbid, identifier.value
        end

        test "call with release_group_musicbrainz_id returns existing album when found" do
          mbid = "f5093c06-23e3-404f-aeaa-40f72885ee3a"
          existing_album = music_albums(:dark_side_of_the_moon)

          # Mock the finder to return existing album
          finder = mock
          finder.expects(:call).returns(existing_album)

          Finder.stubs(:new).returns(finder)

          result = Importer.call(release_group_musicbrainz_id: mbid)

          assert_instance_of DataImporters::ImportResult, result
          assert result.success?
          assert_equal existing_album, result.item
          assert_equal "The Dark Side of the Moon", result.item.title
        end

        test "call with release_group_musicbrainz_id fails when artist import fails" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"

          # Mock ReleaseGroupSearch lookup
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
                          "id" => "unknown-artist-id",
                          "name" => "Unknown Artist"
                        }
                      }
                    ]
                  }
                ]
              }
            )

          # Mock Artist Importer to fail
          DataImporters::Music::Artist::Importer.stubs(:call)
            .with(musicbrainz_id: "unknown-artist-id")
            .raises(StandardError, "Artist import failed")

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(release_group_musicbrainz_id: mbid)

          refute result.success?
          assert_includes result.all_errors.join(", "), "No valid artists found"
        end

        test "call with release_group_musicbrainz_id handles MusicBrainz lookup failure" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"

          # Mock ReleaseGroupSearch lookup to fail
          search_service = mock
          search_service.expects(:lookup_by_release_group_mbid)
            .with(mbid)
            .returns(
              success: false,
              errors: ["Not found"]
            )

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(release_group_musicbrainz_id: mbid)

          refute result.success?
          assert_includes result.all_errors.join(", "), "Not found"
        end

        test "call with release_group_musicbrainz_id validates UUID format" do
          invalid_mbid = "not-a-valid-uuid"

          assert_raises(ArgumentError) do
            Importer.call(release_group_musicbrainz_id: invalid_mbid)
          end
        end

        test "call with release_group_musicbrainz_id processes genres from MusicBrainz data" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"

          # Mock ReleaseGroupSearch lookup with genres
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
                          "id" => "21645c31-fe1c-45a4-955c-3e172b12c3f9",
                          "name" => "Test Artist"
                        }
                      }
                    ],
                    "genres" => [
                      {"name" => "hip hop", "count" => 4},
                      {"name" => "gangsta rap", "count" => 1}
                    ],
                    "tags" => [
                      {"name" => "electronic", "count" => 2}
                    ]
                  }
                ]
              }
            )

          # Mock Artist Importer - return ImportResult (simulates new artist import)
          artist = music_artists(:david_bowie)
          import_result = DataImporters::ImportResult.new(
            item: artist,
            provider_results: [],
            success: true
          )
          DataImporters::Music::Artist::Importer.stubs(:call)
            .returns(import_result)

          ::Music::Musicbrainz::Search::ReleaseGroupSearch.stubs(:new).returns(search_service)

          result = Importer.call(release_group_musicbrainz_id: mbid)

          assert result.success?

          # Check that genre categories are created
          category_names = result.item.categories.where(category_type: "genre").pluck(:name)
          assert_includes category_names, "Hip Hop"
          assert_includes category_names, "Gangsta Rap"
          assert_includes category_names, "Electronic"
        end
      end
    end
  end
end
