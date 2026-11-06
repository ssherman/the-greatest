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
            verdict.update!(applied_at: Time.current) if result.data[:outcome] == :applied
            result
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
