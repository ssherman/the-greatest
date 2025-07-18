# frozen_string_literal: true

require "test_helper"

module Search
  module Music
    module Search
      class ArtistGeneralTest < ActiveSupport::TestCase
        def setup
          # Clean up any existing test data
          cleanup_test_index

          # Create test index
          ::Search::Music::ArtistIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "index_name includes Rails environment" do
          index_name = ::Search::Music::Search::ArtistGeneral.index_name
          assert_match(/^music_artists_test/, index_name)
          # In test environment, should include process ID for parallel testing
          assert_match(/music_artists_test_\d+/, index_name)
        end

        test "call returns empty array for blank text" do
          result = ::Search::Music::Search::ArtistGeneral.call("")
          assert_equal [], result

          result = ::Search::Music::Search::ArtistGeneral.call(nil)
          assert_equal [], result
        end

        test "call finds artists by name" do
          # Create test artist
          artist = music_artists(:the_beatles)

          # Index the artist
          ::Search::Music::ArtistIndex.index(artist)

          # Wait for indexing
          sleep(0.1)

          # Search for the artist
          results = ::Search::Music::Search::ArtistGeneral.call("Beatles")

          # Check results
          assert_equal 1, results.size
          assert_equal artist.id.to_s, results[0][:id]
          assert results[0][:score] > 0
          assert_equal "The Beatles", results[0][:source]["name"]
        end

        test "call returns results ordered by relevance" do
          # Create test artists
          artist1 = music_artists(:the_beatles)
          artist2 = music_artists(:beatles_tribute_band)

          # Index the artists
          ::Search::Music::ArtistIndex.index(artist1)
          ::Search::Music::ArtistIndex.index(artist2)

          # Wait for indexing
          sleep(0.1)

          # Search for "Beatles"
          results = ::Search::Music::Search::ArtistGeneral.call("Beatles")

          # Check results are ordered by relevance (exact match first)
          assert_equal 2, results.size
          assert results[0][:score] >= results[1][:score]
        end

        test "call with custom options" do
          # Create test artist
          artist = music_artists(:the_beatles)

          # Index the artist
          ::Search::Music::ArtistIndex.index(artist)

          # Wait for indexing
          sleep(0.1)

          # Search with custom options
          results = ::Search::Music::Search::ArtistGeneral.call("Beatles", {
            size: 1,
            from: 0,
            min_score: 0.5
          })

          # Check results
          assert_equal 1, results.size
          assert_equal artist.id.to_s, results[0][:id]
        end

        private

        def cleanup_test_index
          ::Search::Music::ArtistIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
          # Index doesn't exist, that's fine
        end
      end
    end
  end
end
