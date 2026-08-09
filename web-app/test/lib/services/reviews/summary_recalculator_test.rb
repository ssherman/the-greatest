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

      test ".recalculate creates no row for a reviewable that has no reviews" do
        assert_equal 0, Review.where(reviewable: @book).count

        assert_no_difference "ReviewSummary.count" do
          recalculate(@book)
        end
        assert_nil summary_for(@book)
      end

      # Both paths must agree on REMOVAL, not just on insert/update. The stale row is
      # re-introduced before each path so each one has to prune it: path A through
      # recalculate's scoped prune, path B through backfill_all!'s global prune. Delete
      # either prune and the stale row survives in that path, the arrays diverge, and
      # this test fails -- which is the whole point of it.
      test "incremental recalculation and a full backfill agree, including removals" do
        Review.create!(user: users(:password_user), reviewable: @book, rating: 2, body: "<p>No.</p>")
        Review.create!(user: users(:google_user), reviewable: @book, rating: 5)

        # delete_all bypasses the after_commit, so the summary row is left stale.
        gone = books_books(:crime_and_punishment)
        Review.where(reviewable: gone).delete_all

        columns = %w[reviewable_type reviewable_id ratings_count ratings_sum text_reviews_count
          rating_1_count rating_2_count rating_3_count rating_4_count rating_5_count]

        seed_stale_state = lambda do
          ReviewSummary.delete_all
          SummaryRecalculator.backfill_all!
          ReviewSummary.create!(reviewable: gone, ratings_count: 1, ratings_sum: 3, rating_3_count: 1)
        end

        # Path A: incremental over every reviewable that has a summary row OR reviews.
        # The zero-review one must be in that set or the delete path never runs.
        seed_stale_state.call
        targets = (ReviewSummary.pluck(:reviewable_type, :reviewable_id) +
          Review.distinct.pluck(:reviewable_type, :reviewable_id)).uniq
        targets.each { |type, id| SummaryRecalculator.recalculate(type, id) }
        incremental = ReviewSummary.order(:reviewable_type, :reviewable_id).pluck(*columns)

        # Path B: full rebuild from the identical stale state, with no wipe first, so
        # backfill_all!'s prune is what has to remove the stale row.
        seed_stale_state.call
        SummaryRecalculator.backfill_all!
        backfilled = ReviewSummary.order(:reviewable_type, :reviewable_id).pluck(*columns)

        assert_equal incremental, backfilled
        assert_nil summary_for(gone),
          "both paths must remove the summary for a reviewable with no reviews"
      end
    end
  end
end
