require "test_helper"

class CategorySearchQueryTest < ActiveSupport::TestCase
  def search(query, **options)
    CategorySearchQuery.call(query, scope: Books::Category, **options)
  end

  test "returns nothing for a blank query" do
    assert_empty search("")
    assert_empty search(nil)
    assert_empty search("   ")
  end

  test "matches on a name substring, regardless of case" do
    assert_includes search("fict"), categories(:books_fiction_genre)
    assert_includes search("FICT"), categories(:books_fiction_genre)
  end

  # The Category axis of the books filter modal depends on this. See the spec's
  # landmines: scoping this by default would break two Playwright tests.
  test "returns every category type when no types are given" do
    results = search("americ", limit: 100)

    assert_includes results, categories(:books_americana_genre)
    assert_includes results, categories(:books_american_history_subject)
    assert_includes results, categories(:books_american_location)
  end

  test "types: narrows to one category_type" do
    results = search("americ", types: [:genre], limit: 100)

    assert_equal [categories(:books_americana_genre)], results
  end

  test "types: accepts several category_types" do
    results = search("americ", types: [:genre, :location], limit: 100)

    assert_includes results, categories(:books_americana_genre)
    assert_includes results, categories(:books_american_location)
    assert_not_includes results, categories(:books_american_history_subject)
  end

  # item_count DESC, not alphabetical: on a table this size the popular match
  # is nearly always the one meant.
  test "orders by item_count descending" do
    results = search("americ", limit: 100)

    assert_equal(
      [categories(:books_american_history_subject), categories(:books_americana_genre), categories(:books_american_location)],
      results.first(3)
    )
  end

  # Searches "retired", the fixture's actual name -- searching "deleted" would
  # match nothing and pass even if `.active` were dropped. The fixture also has
  # the highest item_count of any category (9999), so without `.active` it
  # would not merely appear, it would sort first.
  test "excludes soft-deleted categories" do
    results = search("retired", limit: 100)

    assert_not_includes results, categories(:books_deleted_genre)
    assert_empty results
  end

  test "honours limit" do
    assert_equal 2, search("americ", limit: 2).size
  end

  test "applies the limit after ordering, so the most-used win" do
    assert_equal [categories(:books_american_history_subject)], search("americ", limit: 1)
  end

  test "scope: keeps another domain's categories out" do
    results = CategorySearchQuery.call("rock", scope: Books::Category, limit: 100)

    assert_not_includes results, categories(:music_rock_genre)
  end

  # `%` would otherwise match every row. search_by_name sanitizes it; this
  # pins that the shared query still goes through that scope.
  test "escapes LIKE wildcards in the query" do
    assert_empty search("%", limit: 100)
  end
end
