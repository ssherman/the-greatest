# frozen_string_literal: true

require "test_helper"

module Search
  module Music
    module Search
      class SongByTitleAndArtistsTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index

          ::Search::Music::SongIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "index_name delegates to SongIndex" do
          index_name = ::Search::Music::Search::SongByTitleAndArtists.index_name
          assert_equal ::Search::Music::SongIndex.index_name, index_name
        end

        test "call returns empty array for blank title" do
          result = ::Search::Music::Search::SongByTitleAndArtists.call(title: "", artists: ["Pink Floyd"])
          assert_equal [], result

          result = ::Search::Music::Search::SongByTitleAndArtists.call(title: nil, artists: ["Pink Floyd"])
          assert_equal [], result
        end

        test "call returns empty array for blank artists" do
          result = ::Search::Music::Search::SongByTitleAndArtists.call(title: "Time", artists: [])
          assert_equal [], result

          result = ::Search::Music::Search::SongByTitleAndArtists.call(title: "Time", artists: nil)
          assert_equal [], result
        end

        test "call returns empty array for non-array artists" do
          result = ::Search::Music::Search::SongByTitleAndArtists.call(title: "Time", artists: "Pink Floyd")
          assert_equal [], result
        end

        test "call finds song by title and artist" do
          song = music_songs(:time)

          ::Search::Music::SongIndex.index(song)
          sleep(0.1)

          results = ::Search::Music::Search::SongByTitleAndArtists.call(
            title: "Time",
            artists: ["Pink Floyd"]
          )

          assert_equal 1, results.size
          assert_equal song.id.to_s, results[0][:id]
          assert results[0][:score] > 0
          assert_equal "Time", results[0][:source]["title"]
        end

        test "call finds song with multiple artists when any match" do
          song = music_songs(:time)

          ::Search::Music::SongIndex.index(song)
          sleep(0.1)

          results = ::Search::Music::Search::SongByTitleAndArtists.call(
            title: "Time",
            artists: ["Pink Floyd", "The Beatles"]
          )

          assert_equal 1, results.size
          assert_equal song.id.to_s, results[0][:id]
        end

        test "call returns empty for title match without artist match" do
          song = music_songs(:time)

          ::Search::Music::SongIndex.index(song)
          sleep(0.1)

          results = ::Search::Music::Search::SongByTitleAndArtists.call(
            title: "Time",
            artists: ["The Beatles"],
            min_score: 5.0
          )

          assert_equal 0, results.size
        end

        test "call returns empty for artist match without title match" do
          song = music_songs(:time)

          ::Search::Music::SongIndex.index(song)
          sleep(0.1)

          results = ::Search::Music::Search::SongByTitleAndArtists.call(
            title: "Money",
            artists: ["Pink Floyd"],
            min_score: 5.0
          )

          assert_equal 0, results.size
        end

        test "call uses higher default min_score of 5.0" do
          song = music_songs(:time)

          ::Search::Music::SongIndex.index(song)
          sleep(0.1)

          results_low_score = ::Search::Music::Search::SongByTitleAndArtists.call(
            title: "Time",
            artists: ["Pink Floyd"],
            min_score: 1.0
          )
          assert results_low_score.size > 0

          results_high_score = ::Search::Music::Search::SongByTitleAndArtists.call(
            title: "Time",
            artists: ["Pink Floyd"]
          )
          assert results_high_score.size > 0
        end

        test "call respects custom size option" do
          ::Search::Music::SongIndex.index(music_songs(:time))
          ::Search::Music::SongIndex.index(music_songs(:money))
          sleep(0.1)

          results = ::Search::Music::Search::SongByTitleAndArtists.call(
            title: "Time",
            artists: ["Pink Floyd"],
            size: 1
          )

          assert results.size <= 1
        end

        test "call returns results with expected structure" do
          song = music_songs(:time)

          ::Search::Music::SongIndex.index(song)
          sleep(0.1)

          results = ::Search::Music::Search::SongByTitleAndArtists.call(
            title: "Time",
            artists: ["Pink Floyd"]
          )

          assert_equal 1, results.size
          result = results.first

          assert result.key?(:id)
          assert result.key?(:score)
          assert result.key?(:source)
          assert result[:source].key?("title")
        end

        test "call handles blank artist names in array" do
          song = music_songs(:time)

          ::Search::Music::SongIndex.index(song)
          sleep(0.1)

          results = ::Search::Music::Search::SongByTitleAndArtists.call(
            title: "Time",
            artists: ["", "Pink Floyd", nil]
          )

          assert_equal 1, results.size
          assert_equal song.id.to_s, results[0][:id]
        end

        test "call returns empty when no matches meet min_score threshold" do
          song = music_songs(:time)

          ::Search::Music::SongIndex.index(song)
          sleep(0.1)

          results = ::Search::Music::Search::SongByTitleAndArtists.call(
            title: "Time",
            artists: ["Completely Different Artist"],
            min_score: 50.0
          )

          assert_equal 0, results.size
        end

        private

        def cleanup_test_index
          ::Search::Music::SongIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end
      end
    end
  end
end
