require "test_helper"

module DataImporters
  module Sources
    class LegacyTest < ActiveSupport::TestCase
      test "wraps a found record as one decisive :legacy candidate" do
        book = books_books(:war_and_peace)

        candidates = Legacy.new { book }.call

        assert_equal 1, candidates.size
        assert_equal book, candidates.first.record
        assert_equal [:legacy], candidates.first.sources
        assert candidates.first.decisive?
      end

      test "returns nothing when the lookup finds nothing" do
        assert_equal [], Legacy.new { nil }.call
      end

      test "runs the lookup lazily, once per call" do
        calls = 0
        source = Legacy.new {
          calls += 1
          nil
        }

        assert_equal 0, calls
        source.call
        assert_equal 1, calls
      end

      test "name is :legacy" do
        assert_equal :legacy, Legacy.new { nil }.name
      end
    end
  end
end
