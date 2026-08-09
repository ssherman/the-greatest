# frozen_string_literal: true

require "test_helper"

module Books
  class SavedSearchCriteriaTest < ActiveSupport::TestCase
    def criteria(hash)
      ::Books::SavedSearchCriteria.new(hash)
    end

    test "tolerates a nil raw hash" do
      c = criteria(nil)

      assert_nil c.book_type
      assert_equal [], c.included_category_ids
      assert_equal :any, c.genre_match_mode
      refute c.hide_read
    end

    test "reads id arrays as integers from either shape" do
      from_strings = criteria({"included_category_ids" => ["12", "34"]})
      from_ints = criteria({"included_category_ids" => [12, 34]})

      assert_equal [12, 34], from_strings.included_category_ids
      assert_equal [12, 34], from_ints.included_category_ids
    end

    test "drops blank entries from id arrays rather than reading them as zero" do
      c = criteria({"included_language_ids" => ["12", "", nil]})

      assert_equal [12], c.included_language_ids
    end

    test "reads every id array" do
      c = criteria({
        "included_category_ids" => ["1"], "excluded_category_ids" => ["2"],
        "included_language_ids" => ["3"], "excluded_language_ids" => ["4"],
        "included_country_ids" => ["5"], "excluded_country_ids" => ["6"]
      })

      assert_equal [1], c.included_category_ids
      assert_equal [2], c.excluded_category_ids
      assert_equal [3], c.included_language_ids
      assert_equal [4], c.excluded_language_ids
      assert_equal [5], c.included_country_ids
      assert_equal [6], c.excluded_country_ids
    end

    test "reads book_type from either shape" do
      assert_equal 0, criteria({"book_type" => 0}).book_type
      assert_equal 0, criteria({"book_type" => "0"}).book_type
      assert_nil criteria({}).book_type
      assert_nil criteria({"book_type" => ""}).book_type
    end

    test "reads book_type of nonsense as nil, not zero" do
      assert_nil criteria({"book_type" => "abc"}).book_type
    end

    test "reads book_length as integers, filtering values outside the enum" do
      c = criteria({"book_length" => [1, 2, 99]})

      assert_equal [1, 2], c.book_length
    end

    test "tolerates a scalar book_length" do
      assert_equal [3], criteria({"book_length" => 3}).book_length
      assert_equal [3], criteria({"book_length" => "3"}).book_length
    end

    test "reads publication years from either shape" do
      c = criteria({"first_year_published_gt" => "1980", "first_year_published_lt" => 1990})

      assert_equal 1980, c.first_year_published_gt
      assert_equal 1990, c.first_year_published_lt
    end

    test "reads ranked as a tri-state" do
      assert_equal :ranked, criteria({"ranked" => "true"}).ranked
      assert_equal :ranked, criteria({"ranked" => true}).ranked
      assert_equal :unranked, criteria({"ranked" => "false"}).ranked
      assert_equal :unranked, criteria({"ranked" => false}).ranked
    end

    test "reads an absent or empty ranked as nil, which is not unranked" do
      assert_nil criteria({}).ranked
      assert_nil criteria({"ranked" => ""}).ranked
      assert_nil criteria({"ranked" => nil}).ranked
    end

    test "reads genre_match_mode, defaulting to any" do
      assert_equal :all, criteria({"genre_match_mode" => "all"}).genre_match_mode
      assert_equal :any, criteria({"genre_match_mode" => "any"}).genre_match_mode
      assert_equal :any, criteria({}).genre_match_mode
    end

    test "reads hide_read from either shape" do
      assert criteria({"hide_read" => true}).hide_read
      assert criteria({"hide_read" => "true"}).hide_read
      refute criteria({"hide_read" => false}).hide_read
      refute criteria({}).hide_read
    end

    # A Rails check_box submits "1"; a bare HTML checkbox submits "on". Both
    # must read as true, or a checked box in increment 6's form silently
    # stores as unchecked.
    test "reads hide_read as true for every checkbox-submission shape" do
      assert criteria({"hide_read" => "1"}).hide_read
      assert criteria({"hide_read" => "on"}).hide_read
      assert criteria({"hide_read" => true}).hide_read
    end

    test "reads hide_read as false for every falsy shape, including absence" do
      refute criteria({"hide_read" => "0"}).hide_read
      refute criteria({"hide_read" => "false"}).hide_read
      refute criteria({"hide_read" => ""}).hide_read
      refute criteria({"hide_read" => nil}).hide_read
      refute criteria({}).hide_read
    end

    test "reads max_ranked_position from either shape" do
      assert_equal 100, criteria({"max_ranked_position" => 100}).max_ranked_position
      assert_equal 100, criteria({"max_ranked_position" => "100"}).max_ranked_position
      assert_nil criteria({}).max_ranked_position
    end

    test "reads without touching the database" do
      c = criteria({"book_length" => [1], "book_type" => "0"})
      ::Books::Book.book_lengths # warm the class so its first-touch schema load isn't counted

      assert_queries_count(0) do
        c.book_length
        c.book_type
      end
    end
  end
end
