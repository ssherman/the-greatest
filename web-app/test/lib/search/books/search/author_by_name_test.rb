# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class AuthorByNameTest < ActiveSupport::TestCase
        SEARCH = ::Search::Books::Search::AuthorByName

        def setup
          cleanup_test_index
          ::Search::Books::AuthorIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        def index(*authors)
          authors.each { |author| ::Search::Books::AuthorIndex.index(author) }
          sleep(0.1)
        end

        test "index_name delegates to AuthorIndex" do
          assert_equal ::Search::Books::AuthorIndex.index_name, SEARCH.index_name
        end

        test "returns an empty array for a blank name without searching" do
          SEARCH.expects(:search).never

          assert_equal [], SEARCH.call(name: "")
          assert_equal [], SEARCH.call(name: nil)
        end

        test "returns an empty array without searching when the name normalizes to nothing" do
          SEARCH.expects(:search).never

          assert_equal [], SEARCH.call(name: "***")
        end

        test "finds an author by name and not an unrelated one" do
          tolstoy = books_authors(:tolstoy)
          index(tolstoy, books_authors(:king))

          results = SEARCH.call(name: "Leo Tolstoy")

          assert_equal [tolstoy.id.to_s], results.map { |hit| hit[:id] }
          assert results[0][:score] > 0
        end

        test "finds an author whose alternate name is the query name" do
          tolstoy = books_authors(:tolstoy)
          index(tolstoy)

          assert_equal [tolstoy.id.to_s], SEARCH.call(name: "Lev Tolstoy").map { |hit| hit[:id] }
        end

        test "finds an author from an inverted name" do
          tolstoy = books_authors(:tolstoy)
          index(tolstoy)

          assert_equal [tolstoy.id.to_s], SEARCH.call(name: "Tolstoy, Leo").map { |hit| hit[:id] }
        end

        test "an ASCII spelling finds the accented name" do
          author = ::Books::Author.create!(name: "Gabriel García Márquez")
          index(author)

          assert_equal [author.id.to_s], SEARCH.call(name: "Gabriel Garcia Marquez").map { |hit| hit[:id] }
        end

        test "the query's alternate names rank an author carrying them first" do
          plain = ::Books::Author.create!(name: "Mary Shelley")
          known = ::Books::Author.create!(name: "Mary Shelley", alternate_names: ["Mary Wollstonecraft Godwin"])
          index(plain, known)

          results = SEARCH.call(name: "Mary Shelley", alternate_names: ["Mary Wollstonecraft Godwin"])

          assert_equal known.id.to_s, results.first[:id]
          assert_equal 2, results.size
        end

        private

        def cleanup_test_index
          ::Search::Books::AuthorIndex.delete_index
        rescue OpenSearch::Transport::Transport::Errors::NotFound
        end
      end
    end
  end
end
