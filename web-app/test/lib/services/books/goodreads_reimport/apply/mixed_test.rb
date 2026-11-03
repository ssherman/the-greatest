# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      module Apply
        class MixedTest < ActiveSupport::TestCase
          include GoodreadsReimportApplyHelper

          setup do
            setup_reader
            @mixed = ::Books::Book.create!(title: "Mixed Lump", book_kind: :standalone)
          end

          def mixed_verdict(redirect: @to.id, **attributes)
            ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:#{@mixed.id}", decided_by: :rule,
              status: :approved, **attributes,
              payload: {"book_id" => @mixed.id, "redirect_to_book_id" => redirect, "archive" => {}})
          end

          def copy_verdict(user: @user, applied: true)
            row = csv_row
            verdict = row_verdict(row, action: "copy", from: @mixed)
            verdict.update!(payload: verdict.payload.merge("user_id" => user.id))
            verdict.update!(applied_at: Time.current) if applied
            verdict
          end

          test "a kept mixed book is a final noop and deletes nothing, redirect or not" do
            verdict = mixed_verdict
            verdict.update!(payload: verdict.payload.merge("kept" => true))
            ::Services::BooksMigration::RedirectRecorder.expects(:merged).never

            result = Mixed.call(verdict: verdict)

            assert_equal [:noop, true, "kept: readers matched this book"], result.data.values_at(:outcome, :final, :reason)
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "a kept mixed book with row keys and no redirect is final, not waiting" do
            verdict = mixed_verdict(redirect: nil)
            verdict.update!(payload: verdict.payload.merge("kept" => true, "row_keys" => [[1, 1]]))

            result = Mixed.call(verdict: verdict)

            assert_equal [true, "kept: readers matched this book"], result.data.values_at(:final, :reason)
          end

          test "deletes an empty book and records the redirect after commit" do
            ::Services::BooksMigration::RedirectRecorder.expects(:merged).with(item_type: "Books::Book", from_id: @mixed.id, to_id: @to.id)

            result = Mixed.call(verdict: mixed_verdict)

            assert_equal :applied, result.data[:outcome]
            assert_not ::Books::Book.exists?(@mixed.id)
          end

          test "refuses while a reader's list item is left that no copy accounts for" do
            UserListItem.create!(user_list: list(:read), listable: @mixed)

            result = Mixed.call(verdict: mixed_verdict)

            assert_equal [:noop, false], result.data.values_at(:outcome, :final)
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "refuses while a review is left, even for a user whose row was copied" do
            copy_verdict
            Review.create!(user: @user, reviewable: @mixed, rating: 3, body: "mine")

            assert_equal :noop, Mixed.call(verdict: mixed_verdict).data[:outcome]
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "destroys the originals of an applied copy and records them" do
            item = UserListItem.create!(user_list: list(:read), listable: @mixed, completed_on: Date.new(2020, 5, 5))
            copy_verdict
            verdict = mixed_verdict

            result = Mixed.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_not UserListItem.exists?(item.id)
            deleted = verdict.reload.payload["deleted"].first
            assert_equal [item.id, @user.id, @mixed.id], deleted.values_at("id", "user_id", "listable_id")
          end

          test "another user's item is not a copy original" do
            other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", role: :user, email_verified: false)
            UserListItem.create!(user_list: ::Books::UserList.find_by!(user: other, list_type: :read), listable: @mixed)
            copy_verdict

            assert_equal :noop, Mixed.call(verdict: mixed_verdict).data[:outcome]
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "an unapplied copy for the same user keeps the book" do
            UserListItem.create!(user_list: list(:read), listable: @mixed)
            copy_verdict
            copy_verdict(applied: false)

            assert_equal :noop, Mixed.call(verdict: mixed_verdict).data[:outcome]
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "refuses while a guess is unapplied and deletes once it is applied" do
            item = UserListItem.create!(user_list: list(:read), listable: @mixed)
            guess = guess_verdict(item_type: "UserListItem", item_id: item.id, from: @mixed)
            verdict = mixed_verdict

            assert_equal :noop, Mixed.call(verdict: verdict).data[:outcome]
            assert ::Books::Book.exists?(@mixed.id)

            Guess.call(verdict: guess)
            guess.update!(applied_at: Time.current)

            assert_equal :applied, Mixed.call(verdict: verdict).data[:outcome]
            assert_not ::Books::Book.exists?(@mixed.id)
          end

          test "an unapplied guess with no entry left on the book does not hold it" do
            guess_verdict(item_type: "UserListItem", item_id: 0, from: @mixed)

            assert_equal :applied, Mixed.call(verdict: mixed_verdict).data[:outcome]
          end

          test "acts only on an approved, current verdict" do
            assert_equal :noop, Mixed.call(verdict: mixed_verdict(status: :proposed)).data[:outcome]
            ::Books::RepairVerdict.delete_all
            assert_equal :noop, Mixed.call(verdict: mixed_verdict(superseded_at: Time.current)).data[:outcome]
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "a book that is already gone is a final noop" do
            verdict = mixed_verdict
            @mixed.destroy!

            assert_equal [:noop, true], Mixed.call(verdict: verdict).data.values_at(:outcome, :final)
          end

          test "the verdict records that the redirect was written" do
            verdict = mixed_verdict

            Mixed.call(verdict: verdict)

            assert_equal true, verdict.reload.payload["redirect_written"]
          end

          test "a run that died after the delete writes the owed redirect once, then closes" do
            verdict = mixed_verdict
            ::Services::BooksMigration::RedirectRecorder.stubs(:merged).raises(RuntimeError, "boom").then.returns(nil)

            assert_raises(RuntimeError) { Mixed.call(verdict: verdict) }
            assert_not ::Books::Book.exists?(@mixed.id)
            assert_equal false, verdict.reload.payload["redirect_written"]

            ::Services::BooksMigration::RedirectRecorder.expects(:merged).once.with(item_type: "Books::Book", from_id: @mixed.id, to_id: @to.id)
            Mixed.call(verdict: verdict)
            Mixed.call(verdict: verdict.reload)
            assert_equal true, verdict.reload.payload["redirect_written"]
          end

          test "a book another merge removed first gets no redirect from this verdict" do
            verdict = mixed_verdict
            @mixed.destroy!
            ::Services::BooksMigration::RedirectRecorder.expects(:merged).never

            assert_equal [:noop, true], Mixed.call(verdict: verdict).data.values_at(:outcome, :final)
          end

          test "waits, deleting nothing, while its rows have no redirect target yet" do
            verdict = mixed_verdict(redirect: nil)
            verdict.update_columns(payload: verdict.payload.merge("row_keys" => [[@import.id, 1]]))

            result = Mixed.call(verdict: verdict)

            assert_equal [:noop, "waiting for redirect", false], result.data.values_at(:outcome, :reason, :final)
            assert ::Books::Book.exists?(@mixed.id)
          end

          test "no redirect is written when there is no target" do
            ::Services::BooksMigration::RedirectRecorder.expects(:merged).never

            Mixed.call(verdict: mixed_verdict(redirect: nil))
          end
        end
      end
    end
  end
end
