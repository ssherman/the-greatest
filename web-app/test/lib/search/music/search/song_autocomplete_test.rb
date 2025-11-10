# frozen_string_literal: true

require "test_helper"

module Search
  module Music
    module Search
      class SongAutocompleteTest < ActiveSupport::TestCase
        def setup
          # Clean up any existing test data
          cleanup_test_index

          # Create test index
          ::Search::Music::SongIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "call returns empty array for blank text" do
          result = ::Search::Music::Search::SongAutocomplete.call("")
          assert_equal [], result

          result = ::Search::Music::Search::SongAutocomplete.call(nil)
          assert_equal [], result
        end

        test "call finds songs with partial 3 letter match" do
          # Create test song (using Time fixture)
          song = music_songs(:time)

          # Index the song
          ::Search::Music::SongIndex.index(song)

          # Wait for indexing
          sleep(0.1)

          # Search with just first 3 letters
          results = ::Search::Music::Search::SongAutocomplete.call("tim")

          # Should find Time with partial match
          assert_equal 1, results.size
          assert_equal song.id.to_s, results[0][:id]
          assert results[0][:score] > 0
        end

        test "call finds songs with partial 4 letter match" do
          # Create test song (using Money fixture)
          song = music_songs(:money)

          # Index the song
          ::Search::Music::SongIndex.index(song)

          # Wait for indexing
          sleep(0.1)

          # Search with first 4 letters
          results = ::Search::Music::Search::SongAutocomplete.call("mone")

          # Should find Money with partial match
          assert_equal 1, results.size
          assert_equal song.id.to_s, results[0][:id]
          assert results[0][:score] > 0
        end

        test "call uses lower min_score for fuzzy matching" do
          # Create test song (using wish_you_were_here fixture)
          song = music_songs(:wish_you_were_here)

          # Index the song
          ::Search::Music::SongIndex.index(song)

          # Wait for indexing
          sleep(0.1)

          # Search with partial match (should work with low min_score of 0.1)
          results = ::Search::Music::Search::SongAutocomplete.call("wis")

          # Check results - should find with low min_score
          assert_equal 1, results.size
          assert_equal song.id.to_s, results[0][:id]
        end

        private

        def cleanup_test_index
          ::Search::Music::SongIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
          # Index doesn't exist, that's fine
        end
      end
    end
  end
end
