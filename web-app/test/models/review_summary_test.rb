require "test_helper"

class ReviewSummaryTest < ActiveSupport::TestCase
  test "belongs to a polymorphic reviewable" do
    assert_equal Books::Book, review_summaries(:war_and_peace).reviewable.class
  end

  test "average_rating divides the sum by the count" do
    assert_in_delta 4.333, review_summaries(:war_and_peace).average_rating, 0.001
  end

  test "average_rating is nil when there are no ratings" do
    assert_nil ReviewSummary.new(ratings_count: 0, ratings_sum: 0).average_rating
  end

  test "rating_counts returns a hash keyed 1 through 5" do
    assert_equal({1 => 0, 2 => 0, 3 => 0, 4 => 2, 5 => 1},
      review_summaries(:war_and_peace).rating_counts)
  end

  test "rating_percentage returns the share of ratings at that star" do
    assert_in_delta 66.667, review_summaries(:war_and_peace).rating_percentage(4), 0.001
    assert_in_delta 33.333, review_summaries(:war_and_peace).rating_percentage(5), 0.001
    assert_in_delta 0.0, review_summaries(:war_and_peace).rating_percentage(1), 0.001
  end

  test "rating_percentage returns zero when there are no ratings" do
    assert_in_delta 0.0, ReviewSummary.new(ratings_count: 0).rating_percentage(5), 0.001
  end

  test "rating_percentage raises for a rating outside 1..5" do
    summary = review_summaries(:war_and_peace)
    assert_raises(KeyError) { summary.rating_percentage(0) }
    assert_raises(KeyError) { summary.rating_percentage("5") }
  end

  test "a book reaches its summary through the association" do
    assert_equal review_summaries(:war_and_peace), books_books(:war_and_peace).review_summary
  end
end
