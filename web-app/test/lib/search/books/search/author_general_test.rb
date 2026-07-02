# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class AuthorGeneralTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::AuthorIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "call returns empty array for blank text" do
          assert_equal [], ::Search::Books::Search::AuthorGeneral.call("")
          assert_equal [], ::Search::Books::Search::AuthorGeneral.call(nil)
        end

        test "call finds authors by name" do
          author = books_authors(:tolstoy)
          ::Search::Books::AuthorIndex.index(author)
          sleep(0.1)

          results = ::Search::Books::Search::AuthorGeneral.call("Leo Tolstoy")

          assert_equal 1, results.size
          assert_equal author.id.to_s, results[0][:id]
          assert results[0][:score] > 0
          assert_equal "Leo Tolstoy", results[0][:source]["name"]
        end

        test "call finds authors by alternate name" do
          author = books_authors(:tolstoy)
          ::Search::Books::AuthorIndex.index(author)
          sleep(0.1)

          results = ::Search::Books::Search::AuthorGeneral.call("Lev Nikolayevich Tolstoy")

          assert_equal 1, results.size
          assert_equal author.id.to_s, results[0][:id]
        end

        test "call respects custom options" do
          author = books_authors(:king)
          ::Search::Books::AuthorIndex.index(author)
          sleep(0.1)

          results = ::Search::Books::Search::AuthorGeneral.call("Stephen King", {
            size: 1,
            from: 0,
            min_score: 0.5
          })

          assert_equal 1, results.size
          assert_equal author.id.to_s, results[0][:id]
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
