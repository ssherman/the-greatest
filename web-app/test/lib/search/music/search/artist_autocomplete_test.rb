# frozen_string_literal: true

require "test_helper"

module Search
  module Music
    module Search
      class ArtistAutocompleteTest < ActiveSupport::TestCase
        def setup
          # Clean up any existing test data
          cleanup_test_index

          # Create test index
          ::Search::Music::ArtistIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "call returns empty array for blank text" do
          result = ::Search::Music::Search::ArtistAutocomplete.call("")
          assert_equal [], result

          result = ::Search::Music::Search::ArtistAutocomplete.call(nil)
          assert_equal [], result
        end

        test "call finds artists with partial 3 letter match" do
          # Create test artist (using David Bowie fixture)
          artist = music_artists(:david_bowie)

          # Index the artist
          ::Search::Music::ArtistIndex.index(artist)

          # Wait for indexing
          sleep(0.1)

          # Search with just first 3 letters of "David"
          results = ::Search::Music::Search::ArtistAutocomplete.call("dav")

          # Should find David Bowie with partial match
          assert_equal 1, results.size
          assert_equal artist.id.to_s, results[0][:id]
          assert results[0][:score] > 0
        end

        test "call finds artists with partial 4 letter match" do
          # Create test artist (using Pink Floyd fixture)
          artist = music_artists(:pink_floyd)

          # Index the artist
          ::Search::Music::ArtistIndex.index(artist)

          # Wait for indexing
          sleep(0.1)

          # Search with first 4 letters of "Pink"
          results = ::Search::Music::Search::ArtistAutocomplete.call("pink")

          # Should find Pink Floyd with partial match
          assert_equal 1, results.size
          assert_equal artist.id.to_s, results[0][:id]
          assert results[0][:score] > 0
        end

        test "call uses lower min_score for fuzzy matching" do
          # Create test artist
          artist = music_artists(:the_beatles)

          # Index the artist
          ::Search::Music::ArtistIndex.index(artist)

          # Wait for indexing
          sleep(0.1)

          # Search with partial match (should work with low min_score of 0.1)
          results = ::Search::Music::Search::ArtistAutocomplete.call("beat")

          # Check results - should find with low min_score
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
