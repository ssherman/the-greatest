# frozen_string_literal: true

require "test_helper"

module Search
  module Music
    module Search
      class AlbumByTitleAndArtistsTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index

          ::Search::Music::AlbumIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "index_name delegates to AlbumIndex" do
          index_name = ::Search::Music::Search::AlbumByTitleAndArtists.index_name
          assert_equal ::Search::Music::AlbumIndex.index_name, index_name
        end

        test "call returns empty array for blank title" do
          result = ::Search::Music::Search::AlbumByTitleAndArtists.call(title: "", artists: ["Pink Floyd"])
          assert_equal [], result

          result = ::Search::Music::Search::AlbumByTitleAndArtists.call(title: nil, artists: ["Pink Floyd"])
          assert_equal [], result
        end

        test "call returns empty array for blank artists" do
          result = ::Search::Music::Search::AlbumByTitleAndArtists.call(title: "The Dark Side of the Moon", artists: [])
          assert_equal [], result

          result = ::Search::Music::Search::AlbumByTitleAndArtists.call(title: "The Dark Side of the Moon", artists: nil)
          assert_equal [], result
        end

        test "call returns empty array for non-array artists" do
          result = ::Search::Music::Search::AlbumByTitleAndArtists.call(title: "The Dark Side of the Moon", artists: "Pink Floyd")
          assert_equal [], result
        end

        test "call finds album by title and artist" do
          album = music_albums(:dark_side_of_the_moon)

          ::Search::Music::AlbumIndex.index(album)
          sleep(0.1)

          results = ::Search::Music::Search::AlbumByTitleAndArtists.call(
            title: "The Dark Side of the Moon",
            artists: ["Pink Floyd"]
          )

          assert_equal 1, results.size
          assert_equal album.id.to_s, results[0][:id]
          assert results[0][:score] > 0
          assert_equal "The Dark Side of the Moon", results[0][:source]["title"]
        end

        test "call finds album with multiple artists when any match" do
          album = music_albums(:dark_side_of_the_moon)

          ::Search::Music::AlbumIndex.index(album)
          sleep(0.1)

          results = ::Search::Music::Search::AlbumByTitleAndArtists.call(
            title: "The Dark Side of the Moon",
            artists: ["Pink Floyd", "The Beatles"]
          )

          assert_equal 1, results.size
          assert_equal album.id.to_s, results[0][:id]
        end

        test "call returns empty for title match without artist match" do
          album = music_albums(:dark_side_of_the_moon)

          ::Search::Music::AlbumIndex.index(album)
          sleep(0.1)

          results = ::Search::Music::Search::AlbumByTitleAndArtists.call(
            title: "The Dark Side of the Moon",
            artists: ["The Beatles"],
            min_score: 5.0
          )

          assert_equal 0, results.size
        end

        test "call returns empty for artist match without title match" do
          album = music_albums(:dark_side_of_the_moon)

          ::Search::Music::AlbumIndex.index(album)
          sleep(0.1)

          results = ::Search::Music::Search::AlbumByTitleAndArtists.call(
            title: "Abbey Road",
            artists: ["Pink Floyd"],
            min_score: 5.0
          )

          assert_equal 0, results.size
        end

        test "call uses higher default min_score of 5.0" do
          album = music_albums(:dark_side_of_the_moon)

          ::Search::Music::AlbumIndex.index(album)
          sleep(0.1)

          results_low_score = ::Search::Music::Search::AlbumByTitleAndArtists.call(
            title: "The Dark Side of the Moon",
            artists: ["Pink Floyd"],
            min_score: 1.0
          )
          assert results_low_score.size > 0

          results_high_score = ::Search::Music::Search::AlbumByTitleAndArtists.call(
            title: "The Dark Side of the Moon",
            artists: ["Pink Floyd"]
          )
          assert results_high_score.size > 0
        end

        test "call respects custom size option" do
          ::Search::Music::AlbumIndex.index(music_albums(:dark_side_of_the_moon))
          ::Search::Music::AlbumIndex.index(music_albums(:abbey_road))
          sleep(0.1)

          results = ::Search::Music::Search::AlbumByTitleAndArtists.call(
            title: "The Dark Side of the Moon",
            artists: ["Pink Floyd"],
            size: 1
          )

          assert results.size <= 1
        end

        test "call returns results with expected structure" do
          album = music_albums(:dark_side_of_the_moon)

          ::Search::Music::AlbumIndex.index(album)
          sleep(0.1)

          results = ::Search::Music::Search::AlbumByTitleAndArtists.call(
            title: "The Dark Side of the Moon",
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
          album = music_albums(:dark_side_of_the_moon)

          ::Search::Music::AlbumIndex.index(album)
          sleep(0.1)

          results = ::Search::Music::Search::AlbumByTitleAndArtists.call(
            title: "The Dark Side of the Moon",
            artists: ["", "Pink Floyd", nil]
          )

          assert_equal 1, results.size
          assert_equal album.id.to_s, results[0][:id]
        end

        test "call returns empty when no matches meet min_score threshold" do
          album = music_albums(:dark_side_of_the_moon)

          ::Search::Music::AlbumIndex.index(album)
          sleep(0.1)

          results = ::Search::Music::Search::AlbumByTitleAndArtists.call(
            title: "The Dark Side of the Moon",
            artists: ["Completely Different Artist"],
            min_score: 50.0
          )

          assert_equal 0, results.size
        end

        private

        def cleanup_test_index
          ::Search::Music::AlbumIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end
      end
    end
  end
end
