# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      module Apply
        class LeftoversTest < ActiveSupport::TestCase
          include GoodreadsReimportApplyHelper

          setup do
            setup_reader
            @other = books_books(:crime_and_punishment)
            UserListItem.where(listable: @other).delete_all
          end

          def apply(verdict)
            result = Row.call(verdict: verdict)
            settled = result.data[:outcome] == :applied || (result.data[:outcome] == :noop && result.data[:final])
            verdict.update!(applied_at: Time.current) if settled && verdict.reload.applied_at.nil?
            result
          end

          # Legacy put both entries on the book, the realistic shape: the to-read row finds its item already there.
          def split_rows_with_both_items
            [UserListItem.create!(user_list: list(:read), listable: @from), UserListItem.create!(user_list: list(:want_to_read), listable: @from),
              row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @from),
              row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @to)]
          end

          test "legacy holds both entries and the in-place row applies last: the Read leftover is still cleaned" do
            read, want, a, b = split_rows_with_both_items

            apply(b)
            assert UserListItem.exists?(read.id), "A is not settled yet"
            result = apply(a)

            assert_equal [:noop, true], result.data.values_at(:outcome, :final)
            assert_not UserListItem.exists?(read.id)
            assert UserListItem.exists?(want.id)
          end

          test "an add row heading to the book explains its shelf's item even when it wrote nothing" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            c = row_verdict(csv_row(exclusive_shelf: "read"), action: "add", from: nil, to: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @from)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @to)

            [c, a, b].each { |verdict| apply(verdict) }

            assert UserListItem.exists?(read.id)
          end

          test "a keep row heading to the book explains its shelf's item" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            reading = UserListItem.create!(user_list: list(:reading), listable: @from)
            keep = row_verdict(csv_row(exclusive_shelf: "read"), action: "keep", from: @from, to: @from)
            keep.update!(applied_at: Time.current)
            copy = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)

            apply(copy)

            assert UserListItem.exists?(read.id)
            assert_not UserListItem.exists?(reading.id)
          end

          test "a rejected sibling row means nothing is swept" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @other)
            b.update!(status: :rejected)

            apply(a)

            assert UserListItem.exists?(read.id)
          end

          test "a proposed sibling row means nothing is swept" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @other)
            b.update!(status: :proposed)

            apply(a)

            assert UserListItem.exists?(read.id)
          end

          test "a CSV row of the book with no verdict yet means nothing is swept" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            csv_row(exclusive_shelf: "read", legacy_book_id: @from.id)

            apply(a)

            assert UserListItem.exists?(read.id)
          end

          test "a book merged into this one is followed: a keep row naming the merged-in book explains the item" do
            gone_id = ::Books::Book.maximum(:id) + 1000
            ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "books:#{@from.id}:#{gone_id}", decided_by: :rule, status: :approved,
              payload: {"source_id" => gone_id, "target_id" => @from.id})
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            reading = UserListItem.create!(user_list: list(:reading), listable: @from)
            keep = row_verdict(csv_row(exclusive_shelf: "read"), action: "keep", from: @from, to: @from)
            keep.update!(applied_at: Time.current, payload: keep.payload.merge("to_book_id" => gone_id, "from_book_id" => gone_id))
            copy = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)

            apply(copy)

            assert UserListItem.exists?(read.id)
            assert_not UserListItem.exists?(reading.id)
          end

          test "a crash between the copy and the sweep leaves the verdict unapplied, and the retry cleans" do
            read, _want, a, b = split_rows_with_both_items
            apply(a)
            UserListItem.any_instance.stubs(:destroy!).raises("boom")

            assert_raises(RuntimeError) { Row.call(verdict: b) }

            UserListItem.any_instance.unstub(:destroy!)
            assert_nil b.reload.applied_at
            assert UserListItem.exists?(read.id)
            apply(b)
            assert_not UserListItem.exists?(read.id)
          end

          def lists_on(book, user = @user)
            UserListItem.joins(:user_list).where(listable: book, user_lists: {user_id: user.id}).map { |item| item.user_list.list_type }.sort
          end

          def split_rows
            legacy_read = UserListItem.create!(user_list: list(:read), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @from)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @to)
            [legacy_read, a, b]
          end

          test "rows A (to-read, stays) and B (read, goes) on a non-mixed book: the legacy Read item goes once both applied, and is recorded" do
            legacy_read, a, b = split_rows

            apply(b)
            assert UserListItem.exists?(legacy_read.id), "A is not applied yet, so the book is not settled"
            apply(a)

            assert_equal ["want_to_read"], lists_on(@from)
            assert_equal ["read"], lists_on(@to)
            trail = a.reload.payload["leftovers_removed"]
            assert_equal [legacy_read.id], trail.map { |item| item["id"] }
            assert_equal @user.id, trail.first["user_id"]
          end

          test "rows that all go elsewhere leave the reader no entry on the book" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            reading = UserListItem.create!(user_list: list(:reading), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @other)

            apply(a)
            assert UserListItem.exists?(read.id)
            apply(b)

            assert_empty lists_on(@from)
            assert_equal [read.id, reading.id].sort, b.reload.payload["leftovers_removed"].map { |item| item["id"] }.sort
          end

          test "a favorites item stays while a row of the reader heads to the book and goes when none does" do
            fav = UserListItem.create!(user_list: list(:favorites), listable: @from)
            _legacy, a, b = split_rows
            apply(a)
            apply(b)
            assert UserListItem.exists?(fav.id)
          end

          test "a favorites item goes when no row of the reader heads to the book" do
            fav = UserListItem.create!(user_list: list(:favorites), listable: @from)
            UserListItem.create!(user_list: list(:read), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @other)

            apply(a)
            apply(b)

            assert_not UserListItem.exists?(fav.id)
            assert UserListItem.exists?(user_list: list(:favorites), listable: @to), "copy_other_lists already copied it"
          end

          test "another reader's items and the review are untouched, and so is a reader with no applied copy" do
            _legacy, a, b = split_rows
            review = Review.create!(user: @user, reviewable: @from, rating: 4, body: "mine")
            bystander = User.create!(email: "by-#{SecureRandom.hex(3)}@example.com", role: :user, email_verified: false)
            theirs = UserListItem.create!(user_list: ::Books::UserList.find_by!(user: bystander, list_type: :read), listable: @from)

            apply(a)
            apply(b)

            assert UserListItem.exists?(theirs.id)
            assert_equal @from, review.reload.reviewable
          end

          test "sweeping again removes nothing" do
            _legacy, a, b = split_rows
            apply(a)
            apply(b)

            assert_equal 0, Leftovers.sweep(b, @from, @user)
            assert_equal ["want_to_read"], lists_on(@from)
          end

          test "a retry of the last copy after a crash still ends clean" do
            _legacy, a, b = split_rows
            apply(a)
            Row.call(verdict: b)

            Row.call(verdict: b.reload)

            assert_equal ["want_to_read"], lists_on(@from)
            assert_equal ["read"], lists_on(@to)
          end

          test "a mixed book is left to Apply::Mixed" do
            ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:#{@from.id}", decided_by: :rule, status: :approved,
              payload: {"book_id" => @from.id, "redirect_to_book_id" => @to.id, "row_keys" => []})
            legacy_read, a, b = split_rows
            apply(a)
            apply(b)

            assert UserListItem.exists?(legacy_read.id)
          end
        end
      end
    end
  end
end
