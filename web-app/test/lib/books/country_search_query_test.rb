require "test_helper"

module Books
  class CountrySearchQueryTest < ActiveSupport::TestCase
    test "returns nothing for a blank query" do
      assert_empty Books::CountrySearchQuery.call("")
      assert_empty Books::CountrySearchQuery.call(nil)
      assert_empty Books::CountrySearchQuery.call("   ")
    end

    test "matches on a name substring" do
      assert_includes Books::CountrySearchQuery.call("fren"), books_countries(:french)
    end

    test "matches regardless of case" do
      assert_includes Books::CountrySearchQuery.call("FREN"), books_countries(:french)
    end

    test "excludes the unknown bucket" do
      assert_not_includes Books::CountrySearchQuery.call("n", limit: 100), books_countries(:unknown)
    end

    test "orders by book_count descending, then name" do
      results = Books::CountrySearchQuery.call("n", limit: 100)
      counts = results.map(&:book_count)

      assert_equal counts.sort.reverse, counts
    end

    test "breaks a book_count tie by name ascending" do
      results = Books::CountrySearchQuery.call("n", limit: 100)

      assert_equal %w[french algerian japanese], results.map(&:slug)
    end

    test "applies the limit after ordering" do
      results = Books::CountrySearchQuery.call("n", limit: 1)

      assert_equal [books_countries(:french)], results
    end

    test "escapes LIKE wildcards in the query" do
      assert_empty Books::CountrySearchQuery.call("%", limit: 100)
    end
  end
end
