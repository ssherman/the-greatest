require "test_helper"

module DataImporters
  module Sources
    class OpenSearchTest < ActiveSupport::TestCase
      def setup
        @book = books_books(:war_and_peace)
        @other = books_books(:crime_and_punishment)
      end

      test "calls the search class with the params plus size, loads the hits and scores them" do
        ::Search::Music::Search::AlbumByTitleAndArtists.expects(:call)
          .with(title: "War and Peace", artists: ["Leo Tolstoy"], size: 5)
          .returns([{id: @book.id.to_s, score: 9.5, source: {}}, {id: @other.id.to_s, score: 6.1, source: {}}])

        candidates = OpenSearch.new(
          model_class: ::Books::Book,
          search_class: ::Search::Music::Search::AlbumByTitleAndArtists,
          params: {title: "War and Peace", artists: ["Leo Tolstoy"]}
        ).call

        assert_equal [@book, @other], candidates.map(&:record)
        assert_equal [{opensearch: 9.5}, {opensearch: 6.1}], candidates.map(&:scores)
        assert_equal [[:opensearch]] * 2, candidates.map(&:sources)
      end

      test "passes min_score through when given" do
        ::Search::Music::Search::AlbumByTitleAndArtists.expects(:call)
          .with(title: "x", artists: [], size: 3, min_score: 4.0).returns([])

        OpenSearch.new(
          model_class: ::Books::Book, search_class: ::Search::Music::Search::AlbumByTitleAndArtists,
          params: {title: "x", artists: []}, size: 3, min_score: 4.0
        ).call
      end

      test "drops a hit whose record no longer exists" do
        ::Search::Music::Search::AlbumByTitleAndArtists.stubs(:call).returns([{id: "0", score: 9.5, source: {}}, {id: @book.id.to_s, score: 8.0, source: {}}])

        candidates = OpenSearch.new(model_class: ::Books::Book, search_class: ::Search::Music::Search::AlbumByTitleAndArtists, params: {title: "x", artists: []}).call

        assert_equal [@book], candidates.map(&:record)
      end

      test "returns nothing without calling the search when params are nil" do
        ::Search::Music::Search::AlbumByTitleAndArtists.expects(:call).never

        assert_equal [], OpenSearch.new(model_class: ::Books::Book, search_class: ::Search::Music::Search::AlbumByTitleAndArtists, params: nil).call
      end

      test "lets a search error propagate so the finder can record the failed source" do
        ::Search::Music::Search::AlbumByTitleAndArtists.stubs(:call).raises(StandardError, "opensearch down")

        assert_raises(StandardError) do
          OpenSearch.new(model_class: ::Books::Book, search_class: ::Search::Music::Search::AlbumByTitleAndArtists, params: {title: "x", artists: []}).call
        end
      end

      test "name is :opensearch" do
        assert_equal :opensearch, OpenSearch.new(model_class: ::Books::Book, search_class: nil, params: nil).name
      end
    end
  end
end
