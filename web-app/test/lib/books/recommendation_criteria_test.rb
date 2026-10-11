# frozen_string_literal: true

require "test_helper"

module Books
  class RecommendationCriteriaTest < ActiveSupport::TestCase
    test "reads every stored key through the saved-search readers" do
      c = ::Books::RecommendationCriteria.new(
        "included_category_ids" => ["3", 4], "excluded_category_ids" => [9],
        "genre_match_mode" => "all", "book_length" => ["1", 7],
        "first_year_published_gt" => "1900", "first_year_published_lt" => 2000,
        "max_ranked_position" => "250"
      )
      assert_equal [3, 4], c.included_category_ids
      assert_equal [9], c.excluded_category_ids
      assert_equal :all, c.genre_match_mode
      assert_equal [1], c.book_length, "7 is not a book_length enum value and must be dropped"
      assert_equal 1900, c.first_year_published_gt
      assert_equal 2000, c.first_year_published_lt
      assert_equal 250, c.max_ranked_position
    end

    test "defaults when raw is nil or empty" do
      c = ::Books::RecommendationCriteria.new(nil)
      assert_equal [], c.included_category_ids
      assert_equal :any, c.genre_match_mode
      assert_nil c.max_ranked_position
    end

    test "ignores keys outside KEYS even if stored" do
      c = ::Books::RecommendationCriteria.new("hide_read" => true, "ranked" => "false", "included_language_ids" => [1])
      search = c.to_search_criteria
      assert_equal :ranked, search.ranked, "the candidate pool is always ranked"
      assert_equal false, search.hide_read
      assert_equal [], search.included_language_ids
    end

    test "unparseable? mirrors the saved-search rule" do
      c = ::Books::RecommendationCriteria.new("max_ranked_position" => "abc", "excluded_category_ids" => ["x"])
      assert c.unparseable?("max_ranked_position")
      assert c.unparseable?("excluded_category_ids")
      assert_not ::Books::RecommendationCriteria.new({}).unparseable?("max_ranked_position")
    end

    test "depth defaults to balanced and only accepts the three known values" do
      assert_equal "balanced", RecommendationCriteria.new({}).depth
      assert_equal "deep", RecommendationCriteria.new("depth" => "deep").depth
      assert_equal "balanced", RecommendationCriteria.new("depth" => "sideways").depth
    end

    test "engine_overrides maps depth to engine knobs and balanced to nothing" do
      assert_equal({}, RecommendationCriteria.new({}).engine_overrides)
      assert_equal({quality_scale: 1000, quality_floor: 0.3}, RecommendationCriteria.new("depth" => "safe").engine_overrides,
        "safer bets turns the quality prior on")
      assert_equal({rank_prior_weight: 0}, RecommendationCriteria.new("depth" => "deep").engine_overrides,
        "deep cuts drops the fusion rank prior")
      assert_not_equal RecommendationCriteria.new("depth" => "safe").engine_overrides,
        RecommendationCriteria.new("depth" => "deep").engine_overrides, "the three depths build three different pages"
    end

    test "depth never reaches the search criteria" do
      criteria = RecommendationCriteria.new("depth" => "deep", "max_ranked_position" => 100)
      assert_equal 100, criteria.to_search_criteria.max_ranked_position
      assert_equal :ranked, criteria.to_search_criteria.ranked
    end
  end
end
