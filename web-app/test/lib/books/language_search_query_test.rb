require "test_helper"

module Books
  class LanguageSearchQueryTest < ActiveSupport::TestCase
    test "returns nothing for a blank query" do
      assert_empty Books::LanguageSearchQuery.call("")
      assert_empty Books::LanguageSearchQuery.call(nil)
      assert_empty Books::LanguageSearchQuery.call("   ")
    end

    test "matches on a name substring" do
      assert_includes Books::LanguageSearchQuery.call("russ"), languages(:russian)
    end

    test "matches regardless of case" do
      assert_includes Books::LanguageSearchQuery.call("RUSS"), languages(:russian)
    end

    test "orders by name ascending" do
      # english, french, latin, russian all contain "n".
      results = Books::LanguageSearchQuery.call("n", limit: 100)

      assert_equal results.map(&:name).sort, results.map(&:name)
    end

    test "applies the limit after ordering" do
      results = Books::LanguageSearchQuery.call("n", limit: 1)

      assert_equal [languages(:english)], results
    end

    test "escapes LIKE wildcards in the query" do
      assert_empty Books::LanguageSearchQuery.call("%", limit: 100)
    end
  end
end
