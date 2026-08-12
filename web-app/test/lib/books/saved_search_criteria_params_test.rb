require "test_helper"

module Books
  class SavedSearchCriteriaParamsTest < ActiveSupport::TestCase
    def normalize(hash)
      Books::SavedSearchCriteriaParams.call(hash)
    end

    test "drops unknown keys" do
      assert_equal({}, normalize({"nonsense" => "1", "user_id" => "7"}))
    end

    test "drops blank scalars rather than storing them" do
      result = normalize({"book_type" => "", "first_year_published_gt" => "  ", "max_ranked_position" => nil})

      assert_equal({}, result)
    end

    # A present-but-unparseable value makes the query match nothing (spec §6).
    # Dropping blanks at the boundary keeps the form out of that state.
    test "drops an id array that is entirely blank" do
      assert_equal({}, normalize({"included_category_ids" => ["", nil]}))
    end

    test "casts id arrays to integers and drops unparseable entries" do
      result = normalize({"included_category_ids" => ["12", "", "abc", "34"]})

      assert_equal({"included_category_ids" => [12, 34]}, result)
    end

    test "deduplicates id arrays" do
      result = normalize({"excluded_language_ids" => ["5", "5", "6"]})

      assert_equal({"excluded_language_ids" => [5, 6]}, result)
    end

    test "casts book_type to an integer" do
      assert_equal({"book_type" => 0}, normalize({"book_type" => "0"}))
    end

    test "keeps only book_length values that are real enum values" do
      result = normalize({"book_length" => ["0", "99", "abc", "4"]})

      assert_equal({"book_length" => [0, 4]}, result)
    end

    # Stored as the string "true"/"false" to match all 4,391 migrated rows.
    # "" is the "All Books" option and must drop the key entirely -- storing ""
    # and storing nothing must not be two different shapes in one column.
    test "stores ranked as a string, or not at all" do
      assert_equal({"ranked" => "true"}, normalize({"ranked" => "true"}))
      assert_equal({"ranked" => "false"}, normalize({"ranked" => "false"}))
      assert_equal({}, normalize({"ranked" => ""}))
      assert_equal({}, normalize({"ranked" => "nonsense"}))
    end

    test "stores ranked as a string even when given a native boolean" do
      # A JSON request body preserves true/false; form-urlencoded never does.
      assert_equal({"ranked" => "true"}, normalize({"ranked" => true}))
      assert_equal({"ranked" => "false"}, normalize({"ranked" => false}))
      assert_instance_of String, normalize({"ranked" => true})["ranked"]
    end

    test "stores hide_read only when it is true" do
      assert_equal({"hide_read" => true}, normalize({"hide_read" => "1"}))
      assert_equal({}, normalize({"hide_read" => "0"}))
      assert_equal({}, normalize({"hide_read" => ""}))
    end

    test "stores genre_match_mode only when it is all" do
      assert_equal({"genre_match_mode" => "all"}, normalize({"genre_match_mode" => "all"}))
      assert_equal({}, normalize({"genre_match_mode" => "any"}))
      assert_equal({}, normalize({"genre_match_mode" => ""}))
    end

    test "casts the year bounds to integers" do
      result = normalize({"first_year_published_gt" => "1900", "first_year_published_lt" => "1999"})

      assert_equal({"first_year_published_gt" => 1900, "first_year_published_lt" => 1999}, result)
    end

    test "accepts ActionController::Parameters that have been permitted" do
      params = ActionController::Parameters.new(book_type: "1").permit(:book_type)

      assert_equal({"book_type" => 1}, normalize(params))
    end

    test "returns an empty hash for nil" do
      assert_equal({}, normalize(nil))
    end

    # The whole point: what comes out must read back identically through the
    # reader the query layer uses.
    test "output round-trips through SavedSearchCriteria" do
      criteria = Books::SavedSearchCriteria.new(
        normalize({"ranked" => "true", "book_type" => "2", "included_category_ids" => ["9"]})
      )

      assert_equal :ranked, criteria.ranked
      assert_equal 2, criteria.book_type
      assert_equal [9], criteria.included_category_ids
      assert_not criteria.unparseable?(:book_type)
      assert_not criteria.unparseable?(:included_category_ids)
    end
  end
end
