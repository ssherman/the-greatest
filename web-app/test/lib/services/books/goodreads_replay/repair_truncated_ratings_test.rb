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

        def import(source: :legacy_replay, created_at: Time.current, user: @user, id: nil)
          ::Books::GoodreadsImport.create!({user: user, status: :complete, source: source, created_at: created_at}.merge({id: id}.compact))
        end

        def row(import, book, rating:, number: 1, **attributes)
          edition = goodreads_edition(title: "#{book.title} #{import.id} #{number}", book: book, resolution: :matched, resolved_at: Time.current)
          import.rows.create!({row_number: number, goodreads_edition: edition, exclusive_shelf: "read", rating: BigDecimal(rating)}.merge(attributes))
        end

        def legacy_review(rating:, id: LEGACY_REVIEW_ID, user: @user, book: @book)
          ::Review.create!(id: id, user: user, reviewable: book, rating: rating, body: "From legacy.")
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

        test "a newer whole-star upload beats an older fractional one" do
          review = legacy_review(rating: 3)
          row(import(created_at: 2.days.ago), @book, rating: "3.25")
          row(import(created_at: 1.day.ago), @book, rating: "3")
          ::Services::Reviews::SummaryRecalculator.expects(:recalculate).never

          assert_equal 0, RepairTruncatedRatings.call.data[:repaired]
          assert_equal BigDecimal(3), review.reload.rating
        end

        test "the latest upload is decided by created_at, not by id" do
          review = legacy_review(rating: 3)
          newer = import(created_at: 1.day.ago, id: 900_000)
          older = import(created_at: 2.days.ago, id: 900_001)
          row(newer, @book, rating: "3.75")
          row(older, @book, rating: "3.5")

          RepairTruncatedRatings.call

          assert_equal BigDecimal("3.75"), review.reload.rating
        end

        test "within one upload the dated row beats the undated one, then the lowest row number" do
          review = legacy_review(rating: 3)
          upload = import
          row(upload, @book, rating: "3.5", number: 1)
          row(upload, @book, rating: "3.75", number: 2, date_read: Date.new(2024, 1, 1))
          row(upload, @book, rating: "3.25", number: 3, date_read: Date.new(2024, 1, 1))

          RepairTruncatedRatings.call
          assert_equal BigDecimal("3.75"), review.reload.rating
        end

        test "a book repaired for two users is recalculated once" do
          other_user = User.create!(email: "replayer2@example.com", role: :user, email_verified: false)
          legacy_review(rating: 3)
          other_review = legacy_review(rating: 3, id: LEGACY_REVIEW_ID + 1, user: other_user)
          row(import, @book, rating: "3.75")
          row(import(user: other_user), @book, rating: "3.5")
          ::Services::Reviews::SummaryRecalculator.expects(:recalculate).with("Books::Book", @book.id).once

          assert_equal 2, RepairTruncatedRatings.call.data[:repaired]
          assert_equal BigDecimal("3.5"), other_review.reload.rating
        end

        test "examining groups costs a fixed number of queries however many there are" do
          other_user = User.create!(email: "replayer2@example.com", role: :user, email_verified: false)
          books = [books_books(:war_and_peace), books_books(:got), *::Books::Book.where.not(id: [books_books(:war_and_peace).id, books_books(:got).id]).limit(4)]
          assert_operator books.size, :>=, 4
          users = [@user, other_user]
          uploads = users.map { |user| import(user: user) }
          books.each_with_index do |book, index|
            user = users[index % 2]
            # Reader-changed (2 vs 3.75): examined, never written.
            legacy_review(rating: 2, id: 5000 + index, user: user, book: book)
            row(uploads[index % 2], book, rating: "3.75", number: index + 1)
          end

          small = count_queries { RepairTruncatedRatings.call }
          row(uploads.first, books.first, rating: "3.5", number: 99)
          books.each_with_index { |book, index| row(uploads[index % 2], book, rating: "3.25", number: 100 + index) }
          large = count_queries { RepairTruncatedRatings.call }

          assert_equal small, large
        end

        def count_queries
          count = 0
          counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
          ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
          count
        end
      end
    end
  end
end
