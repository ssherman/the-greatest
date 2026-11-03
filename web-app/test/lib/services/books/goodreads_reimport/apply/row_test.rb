# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      module Apply
        class RowTest < ActiveSupport::TestCase
          include GoodreadsReimportApplyHelper

          setup { setup_reader }

          def review_on(book) = Review.find_by(user: @user, reviewable_type: "Books::Book", reviewable_id: book.id)

          def make_review(book, body: "mine", rating: 4) = Review.create!(user: @user, reviewable: book, rating: rating, body: body)

          test "keep and a superseded keep change nothing" do
            item = UserListItem.create!(user_list: list(:read), listable: @from)

            [row_verdict(csv_row, action: "keep", to: @from),
              row_verdict(csv_row, action: "move", superseded_by: "reimport:row:1:1")].each do |verdict|
              assert_equal :noop, Row.call(verdict: verdict).data[:outcome]
            end
            assert_equal @from, item.reload.listable
          end

          test "an already applied verdict is a no-op" do
            UserListItem.create!(user_list: list(:read), listable: @from)
            verdict = row_verdict(csv_row, action: "move")
            verdict.update_columns(applied_at: Time.current)

            assert_equal :noop, Row.call(verdict: verdict).data[:outcome]
            assert_equal 1, UserListItem.where(listable: @from).count
          end

          test "add writes the row's entries on the destination dated from the row" do
            result = Row.call(verdict: row_verdict(csv_row(date_read: Date.new(2024, 5, 3)), action: "add", from: nil))

            item = list(:read).user_list_items.sole
            assert_equal :applied, result.data[:outcome]
            assert_equal [@to.id, Date.new(2024, 5, 3)], [item.listable_id, item.completed_on]
          end

          test "add writes the CSV review only when the verdict carries it" do
            Row.call(verdict: row_verdict(csv_row(rating: 5, review_body: "great"), action: "add", from: nil, review: false))
            assert_nil review_on(@to)

            UserListItem.where(listable: @to).delete_all
            Row.call(verdict: row_verdict(csv_row(rating: 5, review_body: "great"), action: "add", from: nil, review: true))
            assert_equal "great", review_on(@to).body
          end

          test "add is a no-op when the list already holds the book" do
            item = UserListItem.create!(user_list: list(:read), listable: @to, completed_on: Date.new(2020, 1, 1))
            verdict = row_verdict(csv_row(date_read: Date.new(2024, 5, 3)), action: "add", from: nil)

            result = Row.call(verdict: verdict)

            assert_equal :noop, result.data[:outcome]
            assert_equal [item.id], UserListItem.where(listable: @to).pluck(:id)
            assert_equal Date.new(2020, 1, 1), item.reload.completed_on
          end

          test "add never makes a second review" do
            existing = make_review(@to, body: "first")
            Row.call(verdict: row_verdict(csv_row(rating: 5, review_body: "csv"), action: "add", from: nil, review: true))

            assert_equal [existing.id], Review.where(user: @user, reviewable: @to).pluck(:id)
            assert_equal "first", existing.reload.body
          end

          test "move takes every list item of the user, not just one, and records before and after" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            want = UserListItem.create!(user_list: list(:want_to_read), listable: @from)
            verdict = row_verdict(csv_row, action: "move")

            result = Row.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_equal [@to, @to], [read.reload.listable, want.reload.listable]
            moved = verdict.reload.payload["moved"]
            assert_equal [[read.id, want.id], [read.id, want.id]], [moved["list_item_ids_before"].sort, moved["list_item_ids_after"].sort]
          end

          test "move never touches another user's entry" do
            other = User.create!(email: "other-#{SecureRandom.hex(3)}@example.com", role: :user, email_verified: false)
            theirs = UserListItem.create!(user_list: ::Books::UserList.find_by!(user: other, list_type: :read), listable: @from)
            UserListItem.create!(user_list: list(:read), listable: @from)

            Row.call(verdict: row_verdict(csv_row, action: "move"))

            assert_equal @from, theirs.reload.listable
          end

          test "move into a list that already holds the destination keeps that item, fills its date and removes the old one" do
            kept = UserListItem.create!(user_list: list(:read), listable: @to)
            old = UserListItem.create!(user_list: list(:read), listable: @from, completed_on: Date.new(2022, 2, 2))

            Row.call(verdict: row_verdict(csv_row, action: "move"))

            assert_equal Date.new(2022, 2, 2), kept.reload.completed_on
            assert_not UserListItem.exists?(old.id)
            assert_equal 1, UserListItem.where(user_list: list(:read), listable: @to).count
          end

          test "move carries the review only for the review row" do
            review = make_review(@from)
            UserListItem.create!(user_list: list(:read), listable: @from)

            Row.call(verdict: row_verdict(csv_row, action: "move", review: false))
            assert_equal @from, review.reload.reviewable

            UserListItem.create!(user_list: list(:read), listable: @from)
            Row.call(verdict: row_verdict(csv_row, action: "move", review: true))
            assert_equal @to, review.reload.reviewable
          end

          test "move with a review on the destination keeps that review and drops the old one" do
            old = make_review(@from, body: "old")
            winner = make_review(@to, body: "winner")
            UserListItem.create!(user_list: list(:read), listable: @from)
            verdict = row_verdict(csv_row, action: "move", review: true)

            Row.call(verdict: verdict)

            assert_not Review.exists?(old.id)
            assert_equal [winner.id], Review.where(user: @user, reviewable: @to).pluck(:id)
            assert_equal [old.id, winner.id], verdict.reload.payload["moved"].values_at("review_id_before", "review_id_after")
          end

          test "move is a no-op when the user has nothing on the old book" do
            result = Row.call(verdict: row_verdict(csv_row, action: "move", review: true))

            assert_equal [:noop, "nothing to move"], [result.data[:outcome], result.data[:reason]]
          end

          test "move reports a favorites change as a follow-up" do
            UserListItem.create!(user_list: list(:favorites), listable: @from)

            result = Row.call(verdict: row_verdict(csv_row, action: "move"))

            assert_includes result.data[:follow_ups], :user_favorites
          end

          test "move recalculates both books' review summaries when a review moves" do
            make_review(@from)
            UserListItem.create!(user_list: list(:read), listable: @from)
            ::Services::Reviews::SummaryRecalculator.expects(:recalculate).with("Books::Book", @from.id).at_least_once
            ::Services::Reviews::SummaryRecalculator.expects(:recalculate).with("Books::Book", @to.id).at_least_once

            Row.call(verdict: row_verdict(csv_row, action: "move", review: true))
          end

          test "copy keeps the old item until the mixed book is deleted" do
            old = UserListItem.create!(user_list: list(:read), listable: @from)

            result = Row.call(verdict: row_verdict(csv_row(date_read: Date.new(2024, 5, 3)), action: "copy"))

            assert_equal :applied, result.data[:outcome]
            assert_equal @from, old.reload.listable
            copy = UserListItem.find_by!(user_list: list(:read), listable: @to)
            assert_equal Date.new(2024, 5, 3), copy.completed_on
          end

          test "copy dates each destination from its own row" do
            other = books_books(:crime_and_punishment)
            UserListItem.where(listable: other).delete_all
            UserListItem.create!(user_list: list(:read), listable: @from)

            Row.call(verdict: row_verdict(csv_row(date_read: Date.new(2024, 1, 1)), action: "copy"))
            Row.call(verdict: row_verdict(csv_row(date_read: Date.new(2023, 3, 3)), action: "copy", to: other))

            assert_equal [Date.new(2024, 1, 1), Date.new(2023, 3, 3)],
              [UserListItem.find_by!(listable: @to, user_list: list(:read)).completed_on, UserListItem.find_by!(listable: other, user_list: list(:read)).completed_on]
          end

          test "copy with review true moves the user's review from the old book instead of writing the CSV's" do
            review = make_review(@from, body: "original")
            UserListItem.create!(user_list: list(:read), listable: @from)

            Row.call(verdict: row_verdict(csv_row(rating: 5, review_body: "csv"), action: "copy", review: true))

            assert_equal @to, review.reload.reviewable
            assert_equal ["original"], Review.where(user: @user).where(reviewable: [@from, @to]).pluck(:body)
          end

          test "copy with review true and no review on the old book writes the CSV's" do
            UserListItem.create!(user_list: list(:read), listable: @from)

            Row.call(verdict: row_verdict(csv_row(rating: 5, review_body: "csv"), action: "copy", review: true))

            assert_equal "csv", review_on(@to).body
          end

          test "copy with review false leaves the review on the old book and writes none" do
            review = make_review(@from)
            UserListItem.create!(user_list: list(:read), listable: @from)

            Row.call(verdict: row_verdict(csv_row(rating: 5, review_body: "csv"), action: "copy", review: false))

            assert_equal @from, review.reload.reviewable
            assert_nil review_on(@to)
          end

          test "copy never doubles a review the destination already has" do
            make_review(@from, body: "old")
            winner = make_review(@to, body: "winner")
            UserListItem.create!(user_list: list(:read), listable: @from)

            Row.call(verdict: row_verdict(csv_row(rating: 5, review_body: "csv"), action: "copy", review: true))

            assert_equal [winner.id], Review.where(user: @user, reviewable: @to).pluck(:id)
          end

          test "copy is a no-op when the user has nothing left on the old book" do
            result = Row.call(verdict: row_verdict(csv_row, action: "copy"))

            assert_equal [:noop, "nothing to move"], [result.data[:outcome], result.data[:reason]]
            assert_not UserListItem.exists?(listable: @to)
          end

          test "a destination merged away is followed to the book that survived" do
            gone = ::Books::Book.create!(title: "Merged Away #{SecureRandom.hex(3)}")
            ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [gone.id, @to.id], source: :ai)
            ::DuplicateCandidate.where(item_type: "Books::Book", item_a_id: [gone.id, @to.id].min, item_b_id: [gone.id, @to.id].max)
              .update_all(status: ::DuplicateCandidate.statuses[:merged])
            gone_id = gone.id
            gone.destroy!
            item = UserListItem.create!(user_list: list(:read), listable: @from)
            verdict = row_verdict(csv_row, action: "move")
            verdict.update_columns(payload: verdict.payload.merge("to_book_id" => gone_id))

            Row.call(verdict: verdict)

            assert_equal @to, item.reload.listable
          end

          test "a failure part-way rolls the whole move back" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            make_review(@from)
            Entries.stubs(:move_review).raises(ActiveRecord::RecordInvalid)

            assert_raises(ActiveRecord::RecordInvalid) { Row.call(verdict: row_verdict(csv_row, action: "move", review: true)) }
            assert_equal @from, read.reload.listable
          end
        end
      end
    end
  end
end
