# frozen_string_literal: true

require "test_helper"

module Search
  module Music
    module Search
      class AlbumAutocompleteTest < ActiveSupport::TestCase
        def setup
          # Clean up any existing test data
          cleanup_test_index

          # Create test index
          ::Search::Music::AlbumIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "call returns empty array for blank text" do
          result = ::Search::Music::Search::AlbumAutocomplete.call("")
          assert_equal [], result

          result = ::Search::Music::Search::AlbumAutocomplete.call(nil)
          assert_equal [], result
        end

        test "call finds albums with partial 3 letter match" do
          # Create test album
          album = music_albums(:dark_side_of_the_moon)

          # Index the album
          ::Search::Music::AlbumIndex.index(album)

          # Wait for indexing
          sleep(0.1)

          # Search with just first 3 letters
          results = ::Search::Music::Search::AlbumAutocomplete.call("dar")

          # Should find Dark Side with partial match
          assert_equal 1, results.size
          assert_equal album.id.to_s, results[0][:id]
          assert results[0][:score] > 0
        end

        test "call finds albums with partial 4 letter match" do
          # Create test album
          album = music_albums(:dark_side_of_the_moon)

          # Index the album
          ::Search::Music::AlbumIndex.index(album)

          # Wait for indexing
          sleep(0.1)

          # Search with first 4 letters
          results = ::Search::Music::Search::AlbumAutocomplete.call("dark")

          # Should find Dark Side with partial match
          assert_equal 1, results.size
          assert_equal album.id.to_s, results[0][:id]
          assert results[0][:score] > 0
        end

        test "call uses lower min_score for fuzzy matching" do
          # Create test album
          album = music_albums(:wish_you_were_here)

          # Index the album
          ::Search::Music::AlbumIndex.index(album)

          # Wait for indexing
          sleep(0.1)

          # Search with partial match (should work with low min_score of 0.1)
          results = ::Search::Music::Search::AlbumAutocomplete.call("wis")

          # Check results - should find with low min_score
          assert_equal 1, results.size
          assert_equal album.id.to_s, results[0][:id]
        end

        private

        def cleanup_test_index
          ::Search::Music::AlbumIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
          # Index doesn't exist, that's fine
        end
      end
    end
  end
end
