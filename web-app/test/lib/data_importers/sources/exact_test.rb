require "test_helper"

module DataImporters
  module Sources
    class ExactTest < ActiveSupport::TestCase
      test "returns the scope's records as :exact candidates, capped at the limit" do
        scope = ::Books::Book.where("LOWER(books_books.title) = LOWER(?)", "war and peace")

        candidates = Exact.new(scope: scope).call

        assert_equal [books_books(:war_and_peace)], candidates.map(&:record)
        assert_equal [:exact], candidates.first.sources
      end

      test "returns nothing for an empty scope" do
        assert_equal [], Exact.new(scope: ::Books::Book.where(title: "no such title")).call
      end

      test "caps the number of candidates" do
        candidates = Exact.new(scope: ::Books::Book.all, limit: 2).call

        assert_equal 2, candidates.size
      end

      test "name is :exact" do
        assert_equal :exact, Exact.new(scope: ::Books::Book.none).name
      end
    end
  end
end
