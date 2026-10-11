require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class RepairTruncatedRatingsTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        LEGACY_REVIEW_ID = 4242

        setup do
          @user = User.create!(email: "replayer@example.com", role: :user, email_verified: false)
          @book = books_books(:war_and_peace)
        end

        def import(source: :legacy_replay, created_at: Time.current)
          ::Books::GoodreadsImport.create!(user: @user, status: :complete, source: source, created_at: created_at)
        end

        def row(import, book, rating:, number: 1)
          edition = goodreads_edition(title: "#{book.title} #{import.id}", book: book, resolution: :matched, resolved_at: Time.current)
          import.rows.create!(row_number: number, goodreads_edition: edition, exclusive_shelf: "read", rating: BigDecimal(rating))
        end

        def legacy_review(rating:, id: LEGACY_REVIEW_ID)
          ::Review.create!(id: id, user: @user, reviewable: @book, rating: rating, body: "From legacy.")
        end

        def sum
          ::ReviewSummary.find_by!(reviewable_type: "Books::Book", reviewable_id: @book.id).ratings_sum
        end

        test "restores a rating the legacy site truncated, touching nothing else" do
          review = legacy_review(rating: 3)
          row(import, @book, rating: "3.75")
          updated_at = review.reload.updated_at
          before = sum

          result = RepairTruncatedRatings.call

          review.reload
          assert_equal [BigDecimal("3.75"), "From legacy.", updated_at], [review.rating, review.body, review.updated_at]
          assert_equal BigDecimal("0.75"), sum - before
          assert_equal [true, 1, 1], [result.success?, result.data[:checked], result.data[:repaired]]
        end

        test "a member import never repairs" do
          review = legacy_review(rating: 3)
          row(import(source: :member), @book, rating: "3.75")

          assert_equal 0, RepairTruncatedRatings.call.data[:repaired]
          assert_equal BigDecimal(3), review.reload.rating
        end

        test "a review at the reserved ceiling is never repaired" do
          review = legacy_review(rating: 3, id: ::Services::BooksMigration::RESERVED_CEILINGS.fetch("reviews"))
          row(import, @book, rating: "3.75")

          assert_equal 0, RepairTruncatedRatings.call.data[:repaired]
          assert_equal BigDecimal(3), review.reload.rating
        end

        test "whole-star ratings are never touched" do
          legacy_review(rating: 4)
          row(import, @book, rating: "4")
          ::Services::Reviews::SummaryRecalculator.expects(:recalculate).never

          assert_equal 0, RepairTruncatedRatings.call.data[:repaired]
        end

        test "a rating the reader changed is kept" do
          review = legacy_review(rating: 2)
          row(import, @book, rating: "3.75")

          assert_equal 0, RepairTruncatedRatings.call.data[:repaired]
          assert_equal BigDecimal(2), review.reload.rating
        end

        test "no review on the book writes nothing" do
          row(import, @book, rating: "3.75")

          result = RepairTruncatedRatings.call

          assert_equal [true, 0], [result.success?, result.data[:repaired]]
          assert_equal 0, ::Review.where(user: @user).count
        end

        test "the latest upload wins" do
          review = legacy_review(rating: 3)
          row(import(created_at: 2.days.ago), @book, rating: "3.5")
          row(import(created_at: 1.day.ago), @book, rating: "3.75")

          result = RepairTruncatedRatings.call

          assert_equal [1, 1], [result.data[:checked], result.data[:repaired]]
          assert_equal BigDecimal("3.75"), review.reload.rating
        end

        test "a second run after the sync reverts it repairs again, and a run with nothing to fix writes nothing" do
          review = legacy_review(rating: 3)
          row(import, @book, rating: "3.75")
          RepairTruncatedRatings.call
          assert_equal BigDecimal("3.75"), review.reload.rating

          review.update_columns(rating: 3)
          RepairTruncatedRatings.call
          assert_equal BigDecimal("3.75"), review.reload.rating

          ::Services::Reviews::SummaryRecalculator.expects(:recalculate).never
          assert_equal 0, RepairTruncatedRatings.call.data[:repaired]
        end
      end
    end
  end
end
