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

          test "keep and a superseded keep change nothing and are final, so downstream sees them" do
            item = UserListItem.create!(user_list: list(:read), listable: @from)

            [row_verdict(csv_row, action: "keep", to: @from),
              row_verdict(csv_row, action: "move", superseded_by: "reimport:row:1:1")].each do |verdict|
              result = Row.call(verdict: verdict)
              assert_equal [:noop, true], result.data.values_at(:outcome, :final)
            end
            assert_equal @from, item.reload.listable
          end

          test "a move that carries the review gives it the CSV row's rating and records the old one" do
            review = make_review(@from, rating: 3)
            UserListItem.create!(user_list: list(:read), listable: @from)
            verdict = row_verdict(csv_row(rating: 5), action: "move", review: true)

            Row.call(verdict: verdict)

            assert_equal [@to, 5, "mine"], [review.reload.reviewable, review.rating, review.body]
            assert_equal 3, verdict.reload.payload["moved"]["rating_before"].to_f
          end

          test "a copy that carries the review takes the CSV rating too" do
            review = make_review(@from, rating: 2)
            UserListItem.create!(user_list: list(:read), listable: @from)

            Row.call(verdict: row_verdict(csv_row(rating: 4.5), action: "copy", review: true))

            assert_equal 4.5, review.reload.rating.to_f
          end

          test "a keep that carries the review updates a differing rating, is applied, and is idempotent" do
            review = make_review(@from, rating: 3)
            verdict = row_verdict(csv_row(rating: 5), action: "keep", to: @from, review: true)

            result = Row.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_equal 5, review.reload.rating
            assert_equal 3, verdict.reload.payload["moved"]["rating_before"].to_f
            verdict.update!(applied_at: Time.current)
            assert_equal "already applied", Row.call(verdict: verdict).data[:reason]
            assert_equal 5, review.reload.rating
          end

          test "a keep that carries the review with the same rating stays a final no-op" do
            make_review(@from, rating: 5)

            result = Row.call(verdict: row_verdict(csv_row(rating: 5), action: "keep", to: @from, review: true))

            assert_equal [:noop, true], result.data.values_at(:outcome, :final)
          end

          test "a CSV rating of 0 leaves the review's rating alone" do
            review = make_review(@from, rating: 3)
            UserListItem.create!(user_list: list(:read), listable: @from)

            Row.call(verdict: row_verdict(csv_row(rating: 0), action: "move", review: true))
            Row.call(verdict: row_verdict(csv_row(rating: 0), action: "keep", to: @to, review: true))

            assert_equal 3, review.reload.rating
          end

          test "a row that does not carry the review never changes the rating" do
            review = make_review(@to, rating: 3)

            result = Row.call(verdict: row_verdict(csv_row(rating: 5), action: "keep", to: @to, review: false))

            assert_equal :noop, result.data[:outcome]
            assert_equal 3, review.reload.rating
          end

          test "a rating change recalculates the book's review summary" do
            make_review(@from, rating: 3)
            ::Services::Reviews::SummaryRecalculator.expects(:recalculate).with("Books::Book", @from.id).at_least_once

            Row.call(verdict: row_verdict(csv_row(rating: 5), action: "keep", to: @from, review: true))
          end

          test "a verdict whose row's match is no longer approved waits, unapplied" do
            UserListItem.create!(user_list: list(:read), listable: @from)
            row = csv_row
            verdict = row_verdict(row, action: "move")
            ::Books::RepairVerdict.reimport_match.find_by!(subject_key: "reimport:edition:#{row.goodreads_edition_id}").update!(status: :rejected)

            result = Row.call(verdict: verdict)

            assert_equal [:noop, "match no longer approved", false], result.data.values_at(:outcome, :reason, :final)
            assert_equal 1, UserListItem.where(listable: @from).count
          end

          test "a move that finds nothing to move after it already recorded its trail is applied" do
            verdict = row_verdict(csv_row, action: "move")
            verdict.update_columns(payload: verdict.payload.merge("moved" => {"list_item_ids_before" => [1]}))

            assert_equal :applied, Row.call(verdict: verdict).data[:outcome]
          end

          test "copy of a row that does not carry the review writes its own CSV review, keeping the old one where it is" do
            review = make_review(@from, body: "original")
            UserListItem.create!(user_list: list(:read), listable: @from)

            Row.call(verdict: row_verdict(csv_row(rating: 5, review_body: "csv"), action: "copy", review: false))

            assert_equal @from, review.reload.reviewable
            assert_equal "csv", review_on(@to).body
          end

          test "a keep whose edition match was rejected waits unapplied, and closes after re-approval" do
            row = csv_row
            verdict = row_verdict(row, action: "keep", to: @from)
            match = ::Books::RepairVerdict.reimport_match.find_by!(subject_key: "reimport:edition:#{row.goodreads_edition_id}")
            match.update!(status: :rejected)

            result = Row.call(verdict: verdict)
            assert_equal [:noop, "match no longer approved", false], result.data.values_at(:outcome, :reason, :final)

            match.update!(status: :approved)
            assert_equal [:noop, true], Row.call(verdict: verdict).data.values_at(:outcome, :final)
          end

          test "two rows to one destination give it the carrying row's review whichever applies first" do
            bodies = [true, false].map do |carrier_first|
              Review.where(user: @user).destroy_all
              UserListItem.where(listable: [@from, @to]).delete_all
              UserListItem.create!(user_list: list(:read), listable: @from)
              make_review(@from, body: "legacy")
              carrier = row_verdict(csv_row(rating: 5, review_body: "csv a"), action: "copy", review: true)
              plain = row_verdict(csv_row(rating: 4, review_body: "csv b"), action: "copy", review: false)
              order = carrier_first ? [carrier, plain] : [plain, carrier]
              order.each { |verdict| Row.call(verdict: verdict) }
              [carrier, plain].each(&:destroy)
              review_on(@to).body
            end

            assert_equal %w[legacy legacy], bodies
          end

          test "a copy whose destination is the book the entries already sit on writes this row's shelf in place and closes" do
            UserListItem.create!(user_list: list(:read), listable: @from)
            row = csv_row(exclusive_shelf: "to-read", rating: 0)
            verdict = row_verdict(row, action: "copy", from: @from, to: @from)

            result = Row.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            want = UserListItem.find_by!(user_list: list(:want_to_read), listable: @from)
            assert_equal [want.id], verdict.reload.payload["explained_item_ids"]
            # The old Read item is a copy original; a kept mixed book's Apply::Mixed removes it (apply/mixed_test).
          end

          test "copy of a row with no rating or review writes none" do
            UserListItem.create!(user_list: list(:read), listable: @from)

            Row.call(verdict: row_verdict(csv_row, action: "copy", review: false))

            assert_nil review_on(@to)
          end

          test "record_moved keeps the first trail's destroyed records and before ids" do
            verdict = row_verdict(csv_row, action: "move")
            Entries.record_moved(verdict, "list_item_ids_before" => [1], "list_item_ids_after" => [2], "review_id_before" => 3, "review_id_after" => 4,
              "destroyed_items" => [{"id" => 1}], "destroyed_reviews" => [])
            Entries.record_moved(verdict, "list_item_ids_before" => [], "list_item_ids_after" => [2], "review_id_before" => nil, "review_id_after" => 4,
              "destroyed_items" => [], "destroyed_reviews" => [])

            moved = verdict.reload.payload["moved"]
            assert_equal [[1], [{"id" => 1}], 3], [moved["list_item_ids_before"], moved["destroyed_items"], moved["review_id_before"]]
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

            assert_equal [:noop, true], result.data.values_at(:outcome, :final)
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

          test "copy also puts the destination on the user's Favorites and custom lists, keeping the originals" do
            custom = ::Books::UserList.create!(user: @user, list_type: :custom, name: "Mine")
            fav = UserListItem.create!(user_list: list(:favorites), listable: @from)
            mine = UserListItem.create!(user_list: custom, listable: @from, completed_on: Date.new(2020, 2, 2))
            UserListItem.create!(user_list: list(:read), listable: @from)

            result = Row.call(verdict: row_verdict(csv_row, action: "copy"))

            assert_equal [@from, @from], [fav.reload.listable, mine.reload.listable]
            assert UserListItem.exists?(user_list: list(:favorites), listable: @to)
            assert_equal Date.new(2020, 2, 2), UserListItem.find_by!(user_list: custom, listable: @to).completed_on
            assert_includes result.data[:follow_ups], :user_favorites
          end

          test "copy of a to-read row never puts the destination on Read, Want to Read or Reading from the old book's items" do
            UserListItem.create!(user_list: list(:read), listable: @from, completed_on: Date.new(2020, 1, 1))
            UserListItem.create!(user_list: list(:reading), listable: @from)

            Row.call(verdict: row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy"))

            assert_equal [[list(:want_to_read).id]], [UserListItem.where(listable: @to).pluck(:user_list_id)]
          end

          test "copy skips a list that already holds the destination" do
            UserListItem.create!(user_list: list(:favorites), listable: @from)
            kept = UserListItem.create!(user_list: list(:favorites), listable: @to)

            Row.call(verdict: row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy"))

            assert_equal [kept.id], UserListItem.where(user_list: list(:favorites), listable: @to).pluck(:id)
          end

          test "a review destroyed on a collision is kept whole in the verdict" do
            make_review(@from, body: "the lost words", rating: 2)
            make_review(@to, body: "winner")
            UserListItem.create!(user_list: list(:read), listable: @from)
            verdict = row_verdict(csv_row, action: "move", review: true)

            Row.call(verdict: verdict)

            lost = verdict.reload.payload["moved"]["destroyed_reviews"].sole
            assert_equal ["the lost words", 2, @user.id, @from.id], [lost["body"], lost["rating"].to_i, lost["user_id"], lost["reviewable_id"]]
          end

          test "an item destroyed on a collision is kept whole in the verdict" do
            UserListItem.create!(user_list: list(:read), listable: @to)
            old = UserListItem.create!(user_list: list(:read), listable: @from, completed_on: Date.new(2022, 2, 2))
            verdict = row_verdict(csv_row, action: "move")

            Row.call(verdict: verdict)

            lost = verdict.reload.payload["moved"]["destroyed_items"].sole
            assert_equal [old.id, list(:read).id, @from.id, "2022-02-02"], lost.values_at("id", "user_list_id", "listable_id", "completed_on")
          end

          test "the reading item a read row removes is kept in the verdict" do
            reading = UserListItem.create!(user_list: list(:reading), listable: @to)
            verdict = row_verdict(csv_row(exclusive_shelf: "read"), action: "add", from: nil)

            Row.call(verdict: verdict)

            assert_not UserListItem.exists?(reading.id)
            assert_equal [reading.id], verdict.reload.payload["moved"]["destroyed_items"].map { |item| item["id"] }
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
