# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Song
      class ImporterTest < ActiveSupport::TestCase
        def setup
          # Stub the enrichment job to prevent callback from triggering during tests
          ::Music::EnrichSongRecordingIdsJob.stubs(:perform_in)
        end

        test "call with title creates and imports new song" do
          # Mock MusicBrainz recording search
          search_service = mock
          search_service.expects(:search_by_title)
            .with("Comfortably Numb")
            .returns(
              success: true,
              data: {
                "recordings" => [
                  {
                    "id" => "test-recording-mbid",
                    "title" => "Comfortably Numb",
                    "length" => 382_000,
                    "artist-credit" => [
                      {
                        "artist" => {
                          "id" => "83d91898-7763-47d7-b03b-b92132375c47",
                          "name" => "Pink Floyd"
                        }
                      }
                    ]
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

          # Mock artist importer
          artist = music_artists(:pink_floyd)
          artist_result = DataImporters::ImportResult.new(
            item: artist,
            provider_results: [],
            success: true
          )
          DataImporters::Music::Artist::Importer.stubs(:call).returns(artist_result)

          result = Importer.call(title: "Comfortably Numb")

          assert result.success?
          assert_instance_of ::Music::Song, result.item
          assert_equal "Comfortably Numb", result.item.title
          assert result.item.persisted?
          assert_equal 382, result.item.duration_secs
          assert_includes result.item.artists, artist
        end

        test "call with musicbrainz_recording_id creates and imports new song" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"

          # Mock MusicBrainz recording lookup
          search_service = mock
          search_service.expects(:lookup_by_mbid)
            .with(mbid)
            .returns(
              success: true,
              data: {
                "recordings" => [
                  {
                    "id" => mbid,
                    "title" => "Time",
                    "length" => 413_000,
                    "first-release-date" => "1973-03-01",
                    "artist-credit" => [
                      {
                        "artist" => {
                          "id" => "83d91898-7763-47d7-b03b-b92132375c47",
                          "name" => "Pink Floyd"
                        }
                      }
                    ]
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

          # Mock artist importer
          artist = music_artists(:pink_floyd)
          artist_result = DataImporters::ImportResult.new(
            item: artist,
            provider_results: [],
            success: true
          )
          DataImporters::Music::Artist::Importer.stubs(:call).returns(artist_result)

          result = Importer.call(musicbrainz_recording_id: mbid)

          assert result.success?
          assert_instance_of ::Music::Song, result.item
          assert_equal "Time", result.item.title
          assert result.item.persisted?
          assert_equal 1973, result.item.release_year

          # Check identifier was created
          identifier = result.item.identifiers.find_by(identifier_type: :music_musicbrainz_recording_id)
          assert_equal mbid, identifier.value
        end

        test "call returns existing song when found" do
          existing_song = music_songs(:time)

          # Mock the finder to return existing song
          finder = mock
          finder.expects(:call).returns(existing_song)
          Finder.stubs(:new).returns(finder)

          result = Importer.call(title: "Time")

          assert_instance_of DataImporters::ImportResult, result
          assert result.success?
          assert_equal existing_song, result.item
        end

        test "call fails when all providers fail" do
          # Mock MusicBrainz search to fail
          search_service = mock
          search_service.expects(:search_by_title)
            .with("Unknown Song")
            .raises(StandardError, "Network error")

          ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

          result = Importer.call(title: "Unknown Song")

          # Should fail because provider failed
          refute result.success?
          assert_equal "Unknown Song", result.item.title
          refute result.item.persisted?
          assert_includes result.all_errors.join(", "), "Network error"
        end

        test "call fails when neither title nor musicbrainz_recording_id provided" do
          assert_raises(ArgumentError) do
            Importer.call
          end
        end

        test "call handles multiple artists from MusicBrainz" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b4"

          # Mock MusicBrainz recording lookup with multiple artists
          search_service = mock
          search_service.expects(:lookup_by_mbid)
            .with(mbid)
            .returns(
              success: true,
              data: {
                "recordings" => [
                  {
                    "id" => mbid,
                    "title" => "Collaboration Song",
                    "artist-credit" => [
                      {
                        "artist" => {
                          "id" => "83d91898-7763-47d7-b03b-b92132375c47",
                          "name" => "Pink Floyd"
                        }
                      },
                      {
                        "artist" => {
                          "id" => "5441c29d-3602-4898-b1a1-b77fa23b8e50",
                          "name" => "David Bowie"
                        }
                      }
                    ]
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

          # Mock artist importer for both artists
          artist1 = music_artists(:pink_floyd)
          artist2 = music_artists(:david_bowie)

          artist1_result = DataImporters::ImportResult.new(
            item: artist1,
            provider_results: [],
            success: true
          )
          artist2_result = DataImporters::ImportResult.new(
            item: artist2,
            provider_results: [],
            success: true
          )

          DataImporters::Music::Artist::Importer.stubs(:call)
            .with(name: "Pink Floyd", musicbrainz_id: "83d91898-7763-47d7-b03b-b92132375c47")
            .returns(artist1_result)

          DataImporters::Music::Artist::Importer.stubs(:call)
            .with(name: "David Bowie", musicbrainz_id: "5441c29d-3602-4898-b1a1-b77fa23b8e50")
            .returns(artist2_result)

          result = Importer.call(musicbrainz_recording_id: mbid)

          assert result.success?
          assert_equal "Collaboration Song", result.item.title

          # Check both artists are associated with correct positions
          artist_names = result.item.artists.pluck(:name).sort
          assert_includes artist_names, "Pink Floyd"
          assert_includes artist_names, "David Bowie"

          # Check positions
          song_artist1 = result.item.song_artists.find_by(artist: artist1)
          song_artist2 = result.item.song_artists.find_by(artist: artist2)
          assert_equal 1, song_artist1.position
          assert_equal 2, song_artist2.position
        end

        test "call handles ISRC identifier from MusicBrainz" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b2"

          # Mock MusicBrainz recording lookup with ISRC
          search_service = mock
          search_service.expects(:lookup_by_mbid)
            .with(mbid)
            .returns(
              success: true,
              data: {
                "recordings" => [
                  {
                    "id" => mbid,
                    "title" => "Song with ISRC",
                    "isrc" => "USPR37300012",
                    "artist-credit" => [
                      {
                        "artist" => {
                          "id" => "83d91898-7763-47d7-b03b-b92132375c47",
                          "name" => "Pink Floyd"
                        }
                      }
                    ]
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

          # Mock artist importer
          artist = music_artists(:pink_floyd)
          artist_result = DataImporters::ImportResult.new(
            item: artist,
            provider_results: [],
            success: true
          )
          DataImporters::Music::Artist::Importer.stubs(:call).returns(artist_result)

          result = Importer.call(musicbrainz_recording_id: mbid)

          assert result.success?

          # Check ISRC identifier was created
          isrc_identifier = result.item.identifiers.find_by(identifier_type: :music_isrc)
          assert_equal "USPR37300012", isrc_identifier.value
        end

        test "call handles empty recordings array from MusicBrainz" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b3"

          # Mock MusicBrainz recording lookup with empty results
          search_service = mock
          search_service.expects(:lookup_by_mbid)
            .with(mbid)
            .returns(
              success: true,
              data: {
                "recordings" => []
              }
            )

          ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

          result = Importer.call(musicbrainz_recording_id: mbid)

          # Provider returns success but no data populated
          # Song is created but not saved since no data was populated
          refute result.item.persisted?
        end

        test "call validates UUID format for musicbrainz_recording_id" do
          invalid_mbid = "not-a-valid-uuid"

          assert_raises(ArgumentError) do
            Importer.call(musicbrainz_recording_id: invalid_mbid)
          end
        end

        test "call handles artist import failure gracefully" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b5"

          # Mock MusicBrainz recording lookup
          search_service = mock
          search_service.expects(:lookup_by_mbid)
            .with(mbid)
            .returns(
              success: true,
              data: {
                "recordings" => [
                  {
                    "id" => mbid,
                    "title" => "Song with Failed Artist",
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

          ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

          # Mock artist importer to fail
          failed_result = DataImporters::ImportResult.new(
            item: nil,
            provider_results: [],
            success: false
          )
          DataImporters::Music::Artist::Importer.stubs(:call).returns(failed_result)

          result = Importer.call(musicbrainz_recording_id: mbid)

          # Song import should still succeed even if artist import fails
          assert result.success?
          assert_equal "Song with Failed Artist", result.item.title
          # But no artists should be associated
          assert_equal 0, result.item.artists.count
          # And no orphaned song_artists records
          assert_equal 0, result.item.song_artists.count
        end

        test "call does not create song_artist when artist import returns unpersisted artist" do
          mbid = "6b9a9e04-abd7-4666-86ba-bb220ef4c3b6"

          # Mock MusicBrainz recording lookup
          search_service = mock
          search_service.expects(:lookup_by_mbid)
            .with(mbid)
            .returns(
              success: true,
              data: {
                "recordings" => [
                  {
                    "id" => mbid,
                    "title" => "Song with Unpersisted Artist",
                    "length" => 200_000,
                    "artist-credit" => [
                      {
                        "artist" => {
                          "id" => "unpersisted-artist-id",
                          "name" => "Unpersisted Artist"
                        }
                      }
                    ]
                  }
                ]
              }
            )

          ::Music::Musicbrainz::Search::RecordingSearch.stubs(:new).returns(search_service)

          # Mock artist importer to return success but with unpersisted artist (simulates validation failure)
          unpersisted_artist = ::Music::Artist.new(name: "Unpersisted Artist")
          artist_result = DataImporters::ImportResult.new(
            item: unpersisted_artist,
            provider_results: [],
            success: true
          )
          DataImporters::Music::Artist::Importer.stubs(:call).returns(artist_result)

          result = Importer.call(musicbrainz_recording_id: mbid)

          # Song import should succeed (has title and duration)
          assert result.success?
          assert result.item.persisted?
          assert_equal "Song with Unpersisted Artist", result.item.title

          # Critical: Should NOT have any artists or song_artists because artist wasn't persisted
          assert_equal 0, result.item.artists.count, "Should not associate unpersisted artists"
          assert_equal 0, result.item.song_artists.count, "Should not create SongArtist for unpersisted artists"
        end
      end
    end
  end
end
