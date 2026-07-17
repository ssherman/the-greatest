# frozen_string_literal: true

require "test_helper"

module Search
  module Books
    module Search
      class AuthorAutocompleteTest < ActiveSupport::TestCase
        def setup
          cleanup_test_index
          ::Search::Books::AuthorIndex.create_index
        end

        def teardown
          cleanup_test_index
        end

        test "call returns empty array for blank text" do
          assert_equal [], ::Search::Books::Search::AuthorAutocomplete.call("")
          assert_equal [], ::Search::Books::Search::AuthorAutocomplete.call(nil)
        end

        test "call finds an author by a 3-letter name prefix" do
          author = books_authors(:tolstoy)
          ::Search::Books::AuthorIndex.index(author)
          sleep(0.1)

          results = ::Search::Books::Search::AuthorAutocomplete.call("tol")

          assert_equal 1, results.size
          assert_equal author.id.to_s, results[0][:id]
          assert results[0][:score] > 0
        end

        test "call finds an author by a 4-letter name prefix" do
          author = books_authors(:tolstoy)
          ::Search::Books::AuthorIndex.index(author)
          sleep(0.1)

          results = ::Search::Books::Search::AuthorAutocomplete.call("tols")

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
