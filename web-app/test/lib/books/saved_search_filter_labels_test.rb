require "test_helper"
require "active_record/testing/query_assertions"

class Books::SavedSearchFilterLabelsTest < ActiveSupport::TestCase
  include ActiveRecord::Assertions::QueryAssertions

  def labels(raw)
    ::Books::SavedSearchFilterLabels.call(::Books::SavedSearchCriteria.new(raw))
  end

  def group(groups, label)
    groups.find { |g| g.label == label }
  end

  test "empty criteria produce no groups" do
    assert_empty labels({})
  end

  test "genre_match_mode alone produces no groups" do
    assert_empty labels({"genre_match_mode" => "any"})
  end

  test "names included categories and explains any-mode" do
    fiction = categories(:books_fiction_genre)
    groups = labels({"included_category_ids" => [fiction.id], "genre_match_mode" => "any"})

    g = group(groups, "Including genres")
    assert_equal [fiction.name], g.values
    assert_equal "Books must have at least one of these genres", g.note
  end

  test "explains all-mode differently" do
    fiction = categories(:books_fiction_genre)
    classics = categories(:books_classics_genre)
    groups = labels({
      "included_category_ids" => [fiction.id, classics.id],
      "genre_match_mode" => "all"
    })

    g = group(groups, "Including genres")
    assert_equal [fiction.name, classics.name].sort, g.values.sort
    assert_equal "Books must have all of these genres", g.note
  end

  test "names excluded categories, languages and countries" do
    groups = labels({
      "excluded_category_ids" => [categories(:books_classics_genre).id],
      "included_language_ids" => [languages(:russian).id],
      "excluded_language_ids" => [languages(:latin).id],
      "included_country_ids" => [books_countries(:french).id],
      "excluded_country_ids" => [books_countries(:japanese).id]
    })

    assert_equal [categories(:books_classics_genre).name], group(groups, "Excluding genres").values
    assert_equal [languages(:russian).name], group(groups, "Including languages").values
    assert_equal [languages(:latin).name], group(groups, "Excluding languages").values
    assert_equal [books_countries(:french).name], group(groups, "Including origins").values
    assert_equal [books_countries(:japanese).name], group(groups, "Excluding origins").values
  end

  # An id the query will match nothing on must not render as an empty card --
  # a search returning zero books needs a filter card that explains why.
  test "an id with no record renders as unknown rather than vanishing" do
    groups = labels({"included_category_ids" => [999_999]})
    assert_equal ["Unknown (#999999)"], group(groups, "Including genres").values
  end

  test "the three taxonomies cost exactly one query each, include and exclude together" do
    raw = {
      "included_category_ids" => [categories(:books_fiction_genre).id],
      "excluded_category_ids" => [categories(:books_classics_genre).id],
      "included_language_ids" => [languages(:russian).id],
      "excluded_language_ids" => [languages(:latin).id],
      "included_country_ids" => [books_countries(:french).id],
      "excluded_country_ids" => [books_countries(:japanese).id]
    }
    assert_queries_count(3) { labels(raw) }
  end

  test "criteria with no ids cost no queries at all" do
    assert_queries_count(0) do
      labels({"book_type" => 0, "ranked" => "true", "hide_read" => true})
    end
  end

  test "renders the scalar criteria" do
    groups = labels({
      "book_type" => 0,
      "book_length" => [0],
      "first_year_published_gt" => 1900,
      "first_year_published_lt" => 1950,
      "ranked" => "true",
      "max_ranked_position" => 500,
      "hide_read" => true
    })

    # book_lengths is {very_short: 0, short: 1, medium: 2, moderate: 3,
    # long: 4, very_long: 5} -- 0 is very_short, not short.
    assert_equal ["Fiction"], group(groups, "Book type").values
    assert_equal ["Very Short"], group(groups, "Book length").values
    assert_equal ["Between 1900 and 1950"], group(groups, "Published").values
    assert_equal ["Only ranked books"], group(groups, "Ranking status").values
    assert_equal ["Top 500"], group(groups, "Ranking limit").values
    assert_equal ["Hiding books the owner has read"], group(groups, "Read books").values
  end

  test "renders an open-ended year bound" do
    assert_equal ["After 1900"],
      group(labels({"first_year_published_gt" => 1900}), "Published").values
    assert_equal ["Before 1950"],
      group(labels({"first_year_published_lt" => 1950}), "Published").values
  end

  # BookAdvanced turns an unparseable criterion into a match-nothing clause
  # (spec §6). The card has to say so, or the page shows zero results under a
  # filter list that looks perfectly satisfiable.
  test "flags a criterion that is present but unreadable" do
    groups = labels({"book_type" => "abc", "included_category_ids" => ["xyz"]})

    g = group(groups, "Unreadable filter")
    assert_equal ["Book type", "Included category ids"].sort, g.values.sort
    assert_equal "This search matches no books until it is edited", g.note
  end

  test "a blank criterion is absent, not unreadable" do
    assert_empty labels({"book_type" => "", "included_category_ids" => [""]})
  end

  test "book_length values outside the enum are dropped by the criteria reader" do
    assert_nil group(labels({"book_length" => [99]}), "Book length")
  end
end
