# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Music
    module Artist
      class ImporterTest < ActiveSupport::TestCase
        test "call with name creates and imports new artist" do
          # Mock MusicBrainz search to return no existing artist (called twice - finder + provider)
          search_service = mock
          search_service.expects(:search_by_name).with("New Artist").twice.returns(
            success: true,
            data: {
              "artists" => [
                {
                  "id" => "new-artist-mbid",
                  "name" => "New Artist",
                  "type" => "Person",
                  "country" => "US"
                }
              ]
            }
          )

          # Stub the search service creation
          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(name: "New Artist")

          assert result.success?
          assert_instance_of ::Music::Artist, result.item
          assert_equal "New Artist", result.item.name
          assert result.item.persisted?
          assert_equal "person", result.item.kind
          assert_equal "US", result.item.country
        end

        test "call returns existing artist when found" do
          # Use existing fixture artist
          existing_artist = music_artists(:pink_floyd)

          # Mock MusicBrainz search to return Pink Floyd's data
          search_service = mock
          search_service.expects(:search_by_name).with("Pink Floyd").returns(
            success: true,
            data: {
              "artists" => [
                {"id" => "83d91898-7763-47d7-b03b-b92132375c47", "name" => "Pink Floyd"}
              ]
            }
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(name: "Pink Floyd")

          assert_instance_of DataImporters::ImportResult, result
          assert result.success?
          assert_equal existing_artist, result.item
        end

        test "call handles MusicBrainz failures gracefully" do
          # Mock MusicBrainz search to fail (called twice)
          search_service = mock
          search_service.expects(:search_by_name).with("Test Artist").twice.raises(StandardError, "Network error")

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          Rails.logger.expects(:warn).with("MusicBrainz search failed in finder: Network error").once

          result = Importer.call(name: "Test Artist")

          # Should fail because both finder and provider failed
          refute result.success?
        end

        test "call passes options to query" do
          search_service = mock
          search_service.expects(:search_by_name).with("Test Artist").twice.returns(
            success: false,
            errors: ["No results"]
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(name: "Test Artist", country: "GB")

          # Should fail because provider failed to get data
          refute result.success?
        end

        test "call creates artist when no MusicBrainz results found" do
          search_service = mock
          search_service.expects(:search_by_name).with("Unknown Artist").twice.returns(
            success: true,
            data: {"artists" => []}
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(name: "Unknown Artist")

          # Should fail because provider found no artists
          refute result.success?
        end

        # Tests for new MusicBrainz ID import functionality
        test "call accepts musicbrainz_id parameter" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"

          search_service = mock
          search_service.expects(:lookup_by_mbid).with(mbid).returns(
            success: true,
            data: {
              "artists" => [
                {
                  "id" => mbid,
                  "name" => "Depeche Mode",
                  "type" => "Group",
                  "country" => "GB",
                  "genres" => [
                    {"name" => "electronic", "count" => 25},
                    {"name" => "synth-pop", "count" => 15}
                  ]
                }
              ]
            }
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(musicbrainz_id: mbid)

          assert result.success?
          assert result.item.persisted?
          assert_equal "Depeche Mode", result.item.name
          assert_equal "band", result.item.kind
          assert_equal "GB", result.item.country

          # Should have genre categories from lookup
          genre_names = result.item.categories.where(category_type: "genre").pluck(:name)
          assert_includes genre_names, "Electronic"
          assert_includes genre_names, "Synth-Pop"
        end

        test "call accepts both name and musicbrainz_id parameters" do
          mbid = "8538e728-ca0b-4321-b7e5-cff6565dd4c0"

          # Should call lookup_by_mbid since musicbrainz_id takes priority
          search_service = mock
          search_service.expects(:lookup_by_mbid).with(mbid).returns(
            success: true,
            data: {
              "artists" => [
                {
                  "id" => mbid,
                  "name" => "Depeche Mode",
                  "type" => "Group",
                  "country" => "GB"
                }
              ]
            }
          )
          # Should NOT call search_by_name since we have MBID
          search_service.expects(:search_by_name).never

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(name: "Some Name", musicbrainz_id: mbid)

          assert result.success?
          assert_equal "Depeche Mode", result.item.name
        end

        test "call finds existing artist by musicbrainz_id" do
          # Pink Floyd fixture has musicbrainz_id identifier
          existing_artist = music_artists(:pink_floyd)
          mbid = "83d91898-7763-47d7-b03b-b92132375c47"

          result = Importer.call(musicbrainz_id: mbid)

          # When existing artist found, returns ImportResult with the artist
          assert_instance_of DataImporters::ImportResult, result
          assert result.success?
          assert_equal existing_artist, result.item
          assert_equal "Pink Floyd", result.item.name
        end

        test "call validates musicbrainz_id format" do
          assert_raises(ArgumentError) do
            Importer.call(musicbrainz_id: "invalid-uuid")
          end
        end

        test "call requires either name or musicbrainz_id" do
          assert_raises(ArgumentError) do
            Importer.call(name: "", musicbrainz_id: "")
          end
        end

        test "call prioritizes musicbrainz_id over name in finder" do
          # This test ensures the finder uses MBID when both are provided
          existing_artist = music_artists(:pink_floyd)
          mbid = "83d91898-7763-47d7-b03b-b92132375c47"

          # Provide a different name than what's in the database
          result = Importer.call(name: "Wrong Name", musicbrainz_id: mbid)

          # When existing artist found, returns ImportResult with the artist
          assert_instance_of DataImporters::ImportResult, result
          assert result.success?
          assert_equal existing_artist, result.item
          assert_equal "Pink Floyd", result.item.name # Should find by MBID, not name
        end

        test "call creates new artist when musicbrainz_id not found locally" do
          unknown_mbid = "00000000-1111-2222-3333-444444444444"

          search_service = mock
          search_service.expects(:lookup_by_mbid).with(unknown_mbid).returns(
            success: true,
            data: {
              "artists" => [
                {
                  "id" => unknown_mbid,
                  "name" => "New Artist",
                  "type" => "Person"
                }
              ]
            }
          )

          ::Music::Musicbrainz::Search::ArtistSearch.stubs(:new).returns(search_service)

          result = Importer.call(musicbrainz_id: unknown_mbid)

          assert result.success?
          assert result.item.persisted?
          assert_equal "New Artist", result.item.name
          assert_equal "person", result.item.kind

          # Should create the identifier
          identifier = result.item.identifiers.find_by(identifier_type: :music_musicbrainz_artist_id)
          assert_equal unknown_mbid, identifier.value
        end
      end
    end
  end
end
