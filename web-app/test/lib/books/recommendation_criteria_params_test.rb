# frozen_string_literal: true

require "test_helper"

module Books
  class RecommendationCriteriaParamsTest < ActiveSupport::TestCase
    test "stores only the recommendation keys, normalized" do
      out = ::Books::RecommendationCriteriaParams.call(
        "included_category_ids" => ["3", "", "3"], "excluded_category_ids" => ["9"],
        "genre_match_mode" => "all", "book_length" => ["1", "9"],
        "first_year_published_gt" => "1900", "max_ranked_position" => "250",
        "hide_read" => "1", "ranked" => "false", "included_language_ids" => ["2"]
      )
      assert_equal(
        {"included_category_ids" => [3], "excluded_category_ids" => [9], "genre_match_mode" => "all",
         "book_length" => [1], "first_year_published_gt" => 1900, "max_ranked_position" => 250},
        out
      )
    end

    test "accepts permitted ActionController::Parameters" do
      params = ActionController::Parameters.new(max_ranked_position: "10").permit(:max_ranked_position)
      assert_equal({"max_ranked_position" => 10}, ::Books::RecommendationCriteriaParams.call(params))
    end

    test "blank input stores an empty hash" do
      assert_equal({}, ::Books::RecommendationCriteriaParams.call(nil))
      assert_equal({}, ::Books::RecommendationCriteriaParams.call({"max_ranked_position" => ""}))
    end
  end
end
