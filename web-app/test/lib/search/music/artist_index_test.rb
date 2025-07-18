# frozen_string_literal: true

require "test_helper"

module Search
  module Music
    class ArtistIndexTest < ActiveSupport::TestCase
      def setup
        cleanup_test_index
      end

      def teardown
        cleanup_test_index
      end

      test "index_name includes Rails environment" do
        index_name = ::Search::Music::ArtistIndex.index_name
        assert_match(/^music_artists_test/, index_name)
        # In test environment, should include process ID for parallel testing
        assert_match(/music_artists_test_\d+/, index_name)
      end

      test "index_definition returns correct mapping structure" do
        definition = ::Search::Music::ArtistIndex.index_definition

        assert definition[:settings][:analysis][:analyzer][:folding]
        assert_equal "standard", definition[:settings][:analysis][:analyzer][:folding][:tokenizer]
        assert_equal ["lowercase", "asciifolding"], definition[:settings][:analysis][:analyzer][:folding][:filter]

        properties = definition[:mappings][:properties]
        assert properties[:name]
        assert_equal "text", properties[:name][:type]
        assert_equal "folding", properties[:name][:analyzer]
        assert properties[:name][:fields][:keyword]
        assert_equal "keyword", properties[:name][:fields][:keyword][:type]
        assert_equal "lowercase", properties[:name][:fields][:keyword][:normalizer]
      end

      test "can create and delete index" do
        # Create index
        ::Search::Music::ArtistIndex.create_index
        assert ::Search::Music::ArtistIndex.index_exists?

        # Delete index
        ::Search::Music::ArtistIndex.delete_index
        assert_not ::Search::Music::ArtistIndex.index_exists?
      end

      test "can index and find artist" do
        # Create index
        ::Search::Music::ArtistIndex.create_index

        # Index an artist
        artist = music_artists(:the_beatles)
        ::Search::Music::ArtistIndex.index(artist)

        # Wait for indexing
        sleep(0.1)

        # Find the artist
        result = ::Search::Music::ArtistIndex.find(artist.id)
        assert_equal "The Beatles", result["name"]
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
