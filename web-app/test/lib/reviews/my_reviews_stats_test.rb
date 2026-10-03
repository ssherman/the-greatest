require "test_helper"

module Reviews
  class MyReviewsStatsTest < ActiveSupport::TestCase
    setup do
      @stats = MyReviewsStats.new(user: users(:regular_user), reviewable_class: ::Books::Book)
    end

    test "counts_by_rating always has all five keys, zero-filled" do
      assert_equal (1..5).to_a, @stats.counts_by_rating.keys.sort
      assert @stats.counts_by_rating.values.all? { |value| value.is_a?(Integer) }
    end

    test "every review is either written or rating-only" do
      all = users(:regular_user).reviews.where(reviewable_type: "Books::Book").count
      assert_equal all, @stats.written + @stats.rating_only
      assert_equal users(:regular_user).reviews.where.not(body: nil).count, @stats.written
    end

    test "an unrated written review counts as written but not as rated" do
      before = [@stats.total, @stats.written, @stats.rating_only, @stats.average]
      Review.create!(user: users(:regular_user), reviewable: books_books(:got), body: "<p>No stars.</p>")

      stats = MyReviewsStats.new(user: users(:regular_user), reviewable_class: ::Books::Book)

      assert_equal [before[0], before[1] + 1, before[2], before[3]],
        [stats.total, stats.written, stats.rating_only, stats.average]
    end

    test "average is rounded to one decimal and is a Float" do
      assert_instance_of Float, @stats.average
      assert_equal @stats.average.round(1), @stats.average
    end

    test "average is nil for a user with no reviews" do
      # contractor_user has no reviews in reviews.yml -- reused rather than adding
      # a new fixture, since fixture users have blast radius across other suites.
      stats = MyReviewsStats.new(user: users(:contractor_user), reviewable_class: ::Books::Book)
      assert_nil stats.average
      assert_equal 0, stats.total
      assert_equal 0, stats.percentage_for(5)
    end

    test "percentage_for is a whole number out of the largest bar" do
      assert_includes 0..100, @stats.percentage_for(5)
    end
  end
end
