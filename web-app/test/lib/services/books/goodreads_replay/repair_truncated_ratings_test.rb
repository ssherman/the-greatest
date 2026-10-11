require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class RepairTruncatedRatingsTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        LEGACY_REVIEW_ID = 4242
        # The legacy upload window every happy-path review sits inside.
        UPLOADED = Time.utc(2020, 3, 1, 10)
        COMPLETED = UPLOADED + 1.hour
        DURING = UPLOADED + 10.minutes

        setup do
          @user = User.create!(email: "replayer@example.com", role: :user, email_verified: false)
          @book = books_books(:war_and_peace)
        end

        def import(source: :legacy_replay, user: @user, status: :complete, started_at: UPLOADED, finished_at: COMPLETED, id: nil)
          ::Books::GoodreadsImport.create!({user: user, status: status, source: source, started_at: started_at,
                                            finished_at: finished_at}.merge({id: id}.compact))
        end

        def row(import, book, rating:, number: 1, **attributes)
          edition = goodreads_edition(title: "#{book.title} #{import.id} #{number}", book: book, resolution: :matched, resolved_at: Time.current)
          import.rows.create!({row_number: number, goodreads_edition: edition, exclusive_shelf: "read", rating: BigDecimal(rating)}.merge(attributes))
        end

        # By default a review the legacy importer created inside the window and nothing touched since.
        def legacy_review(rating:, id: LEGACY_REVIEW_ID, user: @user, book: @book, created_at: DURING, updated_at: created_at)
          ::Review.create!(id: id, user: user, reviewable: book, rating: rating, body: "From legacy.", created_at: created_at, updated_at: updated_at)
        end

        def sum
          ::ReviewSummary.find_by!(reviewable_type: "Books::Book", reviewable_id: @book.id).ratings_sum
        end

        def refute_repaired(review, stored: BigDecimal(3))
          ::Services::Reviews::SummaryRecalculator.expects(:recalculate).never
          assert_equal 0, RepairTruncatedRatings.call.data[:repaired]
          assert_equal stored, review.reload.rating
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

          refute_repaired(review)
        end

        test "a review at the reserved ceiling is never repaired" do
          review = legacy_review(rating: 3, id: ::Services::BooksMigration::RESERVED_CEILINGS.fetch("reviews"))
          row(import, @book, rating: "3.75")

          refute_repaired(review)
        end

        test "whole-star ratings are never touched" do
          review = legacy_review(rating: 4)
          row(import, @book, rating: "4")

          refute_repaired(review, stored: BigDecimal(4))
        end

        test "a rating the reader changed is kept" do
          review = legacy_review(rating: 2)
          row(import, @book, rating: "3.75")

          refute_repaired(review, stored: BigDecimal(2))
        end

        test "no review on the book writes nothing" do
          row(import, @book, rating: "3.75")

          result = RepairTruncatedRatings.call

          assert_equal [true, 0], [result.success?, result.data[:repaired]]
          assert_equal 0, ::Review.where(user: @user).count
        end

        test "a review that predates every import window is left alone" do
          review = legacy_review(rating: 3, created_at: UPLOADED - 1.day)
          row(import, @book, rating: "3.75")

          refute_repaired(review)
        end

        test "a review edited later is left alone, even inside the creation segment" do
          review = legacy_review(rating: 3, updated_at: DURING + 1.minute)
          row(import, @book, rating: "3.75")

          refute_repaired(review)
        end

        test "a reader who set 3 deliberately after the CSV said 3.75 is not overwritten" do
          review = legacy_review(rating: 3, updated_at: COMPLETED + 2.days)
          row(import, @book, rating: "3.75")

          refute_repaired(review)
        end

        test "a review created inside a failed import's window is repaired" do
          review = legacy_review(rating: 3)
          row(import(status: :failed), @book, rating: "3.75")

          assert_equal 1, RepairTruncatedRatings.call.data[:repaired]
          assert_equal BigDecimal("3.75"), review.reload.rating
        end

        test "a newer failed upload whose window misses the review is ignored" do
          review = legacy_review(rating: 3)
          row(import, @book, rating: "3.75")
          row(import(status: :failed, started_at: UPLOADED + 5.days, finished_at: UPLOADED + 5.days + 1.minute), @book, rating: "3.25")

          assert_equal 1, RepairTruncatedRatings.call.data[:repaired]
          assert_equal BigDecimal("3.75"), review.reload.rating
        end

        test "two imports whose windows both contain the review is ambiguous and repairs nothing" do
          review = legacy_review(rating: 3)
          row(import, @book, rating: "3.75")
          row(import(started_at: UPLOADED + 5.minutes, finished_at: COMPLETED + 1.hour), @book, rating: "3.5")

          refute_repaired(review)
        end

        test "a replay import with no timing proves nothing" do
          review = legacy_review(rating: 3)
          row(import(started_at: nil, finished_at: nil), @book, rating: "3.75")

          refute_repaired(review)
        end

        test "rows rated under 1 are ignored when the rest agree" do
          review = legacy_review(rating: 3)
          upload = import
          row(upload, @book, rating: "0.5", number: 1)
          row(upload, @book, rating: "3.75", number: 2)
          row(upload, @book, rating: "3.75", number: 3)

          assert_equal 1, RepairTruncatedRatings.call.data[:repaired]
          assert_equal BigDecimal("3.75"), review.reload.rating
        end

        test "rows for the book that disagree on the rating are skipped" do
          review = legacy_review(rating: 3)
          upload = import
          row(upload, @book, rating: "3.75", number: 1)
          row(upload, @book, rating: "3.25", number: 2)

          refute_repaired(review)
        end

        test "a long window does not match a review created in its middle" do
          review = legacy_review(rating: 3, created_at: UPLOADED - 45.days)
          row(import(started_at: UPLOADED - 90.days, finished_at: UPLOADED), @book, rating: "3.75")

          refute_repaired(review)
        end

        test "a review created before the upload began is not the import's" do
          review = legacy_review(rating: 3, created_at: UPLOADED - 1.hour)
          row(import, @book, rating: "3.75")

          refute_repaired(review)
        end

        test "a review created after a short import finished is not the import's" do
          review = legacy_review(rating: 3, created_at: UPLOADED + 2.hours)
          row(import(finished_at: UPLOADED + 2.minutes), @book, rating: "3.75")

          refute_repaired(review)
        end

        test "a long window matches a review created shortly after its start" do
          review = legacy_review(rating: 3, created_at: UPLOADED - 90.days + 1.hour)
          row(import(started_at: UPLOADED - 90.days, finished_at: UPLOADED), @book, rating: "3.75")

          assert_equal 1, RepairTruncatedRatings.call.data[:repaired]
          assert_equal BigDecimal("3.75"), review.reload.rating
        end

        test "a retry shortly after a failed upload is the only import that matches" do
          review = legacy_review(rating: 3, created_at: UPLOADED + 35.minutes)
          row(import(status: :failed, finished_at: UPLOADED + 10.minutes), @book, rating: "3.25")
          row(import(started_at: UPLOADED + 30.minutes, finished_at: UPLOADED + 40.minutes), @book, rating: "3.75")

          assert_equal 1, RepairTruncatedRatings.call.data[:repaired]
          assert_equal BigDecimal("3.75"), review.reload.rating
        end

        test "a review created just before a long import's finish is a re-execution and is repaired" do
          review = legacy_review(rating: 3, created_at: UPLOADED - 1.hour)
          row(import(started_at: UPLOADED - 90.days, finished_at: UPLOADED), @book, rating: "3.75")

          assert_equal 1, RepairTruncatedRatings.call.data[:repaired]
          assert_equal BigDecimal("3.75"), review.reload.rating
        end

        test "a second run after the sync reverts it repairs again, and a run with nothing to fix writes nothing" do
          review = legacy_review(rating: 3)
          row(import, @book, rating: "3.75")
          RepairTruncatedRatings.call
          assert_equal BigDecimal("3.75"), review.reload.rating

          # The sync writes legacy's integer back and keeps legacy's timestamps.
          review.update_columns(rating: 3)
          RepairTruncatedRatings.call
          assert_equal BigDecimal("3.75"), review.reload.rating

          refute_repaired(review, stored: BigDecimal("3.75"))
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

        test "books already repaired are recalculated even when a later repair fails" do
          other_user = User.create!(email: "replayer2@example.com", role: :user, email_verified: false)
          other_book = books_books(:got)
          legacy_review(rating: 3)
          legacy_review(rating: 3, id: LEGACY_REVIEW_ID + 1, user: other_user, book: other_book)
          row(import, @book, rating: "3.75")
          row(import(user: other_user), other_book, rating: "3.75")
          ActiveRecord::Relation.any_instance.stubs(:update_all).returns(1).then.raises(ActiveRecord::StatementInvalid, "boom")
          ::Services::Reviews::SummaryRecalculator.expects(:recalculate).once

          assert_raises(ActiveRecord::StatementInvalid) { RepairTruncatedRatings.call }
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
          third_user = User.create!(email: "replayer3@example.com", role: :user, email_verified: false)
          third_upload = import(user: third_user)
          books.each_with_index do |book, index|
            legacy_review(rating: 2, id: 6000 + index, user: third_user, book: book)
            row(third_upload, book, rating: "3.25", number: index + 1)
          end
          extra = ::Books::Book.where.not(id: books.map(&:id)).limit(2).to_a
          extra.each_with_index do |book, index|
            legacy_review(rating: 2, id: 7000 + index, user: @user, book: book)
            row(uploads.first, book, rating: "3.5", number: 200 + index)
          end
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
