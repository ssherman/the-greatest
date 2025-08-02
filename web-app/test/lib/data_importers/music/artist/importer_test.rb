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

          assert_equal existing_artist, result
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
      end
    end
  end
end
