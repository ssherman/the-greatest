require "test_helper"

module Books
  class CategorySearchQueryTest < ActiveSupport::TestCase
    test "returns nothing for a blank query" do
      assert_empty Books::CategorySearchQuery.call("")
      assert_empty Books::CategorySearchQuery.call(nil)
      assert_empty Books::CategorySearchQuery.call("   ")
    end

    test "matches on a name substring" do
      assert_includes Books::CategorySearchQuery.call("fict"), categories(:books_fiction_genre)
    end

    test "matches regardless of case" do
      assert_includes Books::CategorySearchQuery.call("FICT"), categories(:books_fiction_genre)
    end

    test "returns every category type, not just genres" do
      results = Books::CategorySearchQuery.call("c", limit: 100)

      assert_includes results, categories(:books_fiction_genre)
      assert_includes results, categories(:books_politics_subject)
      assert_includes results, categories(:books_france_location)
    end

    test "excludes soft-deleted categories" do
      assert_not_includes Books::CategorySearchQuery.call("Retired"), categories(:books_deleted_genre)
    end

    test "excludes other media types" do
      assert_not_includes Books::CategorySearchQuery.call("Rock", limit: 100), categories(:music_rock_genre)
    end

    test "orders by item_count descending, then name" do
      results = Books::CategorySearchQuery.call("c", limit: 100)
      counts = results.map(&:item_count)

      assert_equal counts.sort.reverse, counts
    end

    test "applies the limit after ordering, so the most-used win" do
      results = Books::CategorySearchQuery.call("c", limit: 1)

      assert_equal [categories(:books_fiction_genre)], results
    end

    test "escapes LIKE wildcards in the query" do
      assert_empty Books::CategorySearchQuery.call("%zzz")
    end
  end
end
