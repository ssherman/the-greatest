require "test_helper"

module Services
  module Reviews
    class SummaryRecalculatorTest < ActiveSupport::TestCase
      setup do
        @book = books_books(:got)
      end

      def summary_for(book)
        ReviewSummary.find_by(reviewable_type: "Books::Book", reviewable_id: book.id)
      end

      def recalculate(book)
        SummaryRecalculator.recalculate("Books::Book", book.id)
      end

      test ".recalculate creates a summary row from existing reviews" do
        Review.create!(user: users(:regular_user), reviewable: @book, rating: 5, body: "<p>Yes.</p>")
        Review.create!(user: users(:admin_user), reviewable: @book, rating: 3)

        recalculate(@book)
        summary = summary_for(@book)

        assert_equal 2, summary.ratings_count
        assert_equal 8, summary.ratings_sum
        assert_equal 1, summary.text_reviews_count
        assert_equal 1, summary.rating_3_count
        assert_equal 1, summary.rating_5_count
        assert_equal 0, summary.rating_1_count
      end

      test ".recalculate updates an existing summary row" do
        book = books_books(:war_and_peace)
        Review.create!(user: users(:password_user), reviewable: book, rating: 1)

        recalculate(book)
        summary = summary_for(book)

        assert_equal 4, summary.ratings_count
        assert_equal 14, summary.ratings_sum
        assert_equal 1, summary.rating_1_count
      end

      test ".recalculate deletes the row when the last review is gone" do
        review = Review.create!(user: users(:regular_user), reviewable: @book, rating: 4)
        recalculate(@book)
        assert_not_nil summary_for(@book)

        review.destroy!
        recalculate(@book)
        assert_nil summary_for(@book)
      end

      test ".recalculate is idempotent" do
        Review.create!(user: users(:regular_user), reviewable: @book, rating: 4)
        recalculate(@book)
        recalculate(@book)

        assert_equal 1, ReviewSummary.where(reviewable_type: "Books::Book", reviewable_id: @book.id).count
        assert_equal 1, summary_for(@book).ratings_count
      end

      test ".backfill_all! rebuilds every summary from the reviews table" do
        ReviewSummary.delete_all
        SummaryRecalculator.backfill_all!

        summary = summary_for(books_books(:war_and_peace))
        assert_equal 3, summary.ratings_count
        assert_equal 13, summary.ratings_sum
        assert_equal 2, summary.text_reviews_count
        assert_equal 2, summary.rating_4_count
        assert_equal 1, summary.rating_5_count
      end

      test ".backfill_all! prunes summaries whose reviews are gone" do
        Review.where(reviewable: books_books(:crime_and_punishment)).delete_all
        SummaryRecalculator.backfill_all!

        assert_nil summary_for(books_books(:crime_and_punishment))
      end

      test ".backfill_all! returns the number of summary rows" do
        ReviewSummary.delete_all
        assert_equal 2, SummaryRecalculator.backfill_all!
      end

      test "incremental recalculation and a full backfill agree" do
        Review.create!(user: users(:password_user), reviewable: @book, rating: 2, body: "<p>No.</p>")
        Review.create!(user: users(:google_user), reviewable: @book, rating: 5)
        Review.where(reviewable: books_books(:crime_and_punishment)).delete_all

        columns = %w[reviewable_type reviewable_id ratings_count ratings_sum text_reviews_count
          rating_1_count rating_2_count rating_3_count rating_4_count rating_5_count]

        ReviewSummary.delete_all
        Review.distinct.pluck(:reviewable_type, :reviewable_id).each do |type, id|
          SummaryRecalculator.recalculate(type, id)
        end
        incremental = ReviewSummary.order(:reviewable_type, :reviewable_id).pluck(*columns)

        ReviewSummary.delete_all
        SummaryRecalculator.backfill_all!
        backfilled = ReviewSummary.order(:reviewable_type, :reviewable_id).pluck(*columns)

        assert_equal incremental, backfilled
      end
    end
  end
end
