# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      module Apply
        class GuessTest < ActiveSupport::TestCase
          include GoodreadsReimportApplyHelper

          setup { setup_reader }

          test "a hand-added list item moves to the guessed book" do
            item = UserListItem.create!(user_list: list(:read), listable: @from, completed_on: Date.new(2021, 1, 1))
            verdict = guess_verdict(item_type: "UserListItem", item_id: item.id)

            result = Guess.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_equal [@to, Date.new(2021, 1, 1)], [item.reload.listable, item.completed_on]
            assert_equal [[item.id], [item.id]], verdict.reload.payload["moved"].values_at("list_item_ids_before", "list_item_ids_after")
          end

          test "a list that already holds the guessed book keeps its item, gets the blank date, and loses the stray" do
            kept = UserListItem.create!(user_list: list(:read), listable: @to)
            stray = UserListItem.create!(user_list: list(:read), listable: @from, completed_on: Date.new(2021, 1, 1))

            Guess.call(verdict: guess_verdict(item_type: "UserListItem", item_id: stray.id))

            assert_equal Date.new(2021, 1, 1), kept.reload.completed_on
            assert_not UserListItem.exists?(stray.id)
          end

          test "a review moves to the guessed book" do
            review = Review.create!(user: @user, reviewable: @from, rating: 3, body: "hand written")

            result = Guess.call(verdict: guess_verdict(item_type: "Review", item_id: review.id))

            assert_equal :applied, result.data[:outcome]
            assert_equal @to, review.reload.reviewable
          end

          test "a review loses to one the user already wrote on the guessed book" do
            stray = Review.create!(user: @user, reviewable: @from, rating: 3, body: "stray")
            winner = Review.create!(user: @user, reviewable: @to, rating: 5, body: "winner")

            Guess.call(verdict: guess_verdict(item_type: "Review", item_id: stray.id))

            assert_not Review.exists?(stray.id)
            assert_equal "winner", winner.reload.body
          end

          test "an entry that has left the book already is a no-op" do
            item = UserListItem.create!(user_list: list(:read), listable: books_books(:crime_and_punishment))

            result = Guess.call(verdict: guess_verdict(item_type: "UserListItem", item_id: item.id))

            assert_equal [:noop, "nothing to move"], [result.data[:outcome], result.data[:reason]]
          end

          test "another user's entry is never moved, whatever the payload says" do
            other = User.create!(email: "other-#{SecureRandom.hex(3)}@example.com", role: :user, email_verified: false)
            theirs = UserListItem.create!(user_list: ::Books::UserList.find_by!(user: other, list_type: :read), listable: @from)
            review = Review.create!(user: other, reviewable: @from, rating: 3)

            [guess_verdict(item_type: "UserListItem", item_id: theirs.id), guess_verdict(item_type: "Review", item_id: review.id)].each do |verdict|
              assert_equal :noop, Guess.call(verdict: verdict).data[:outcome]
            end
            assert_equal [@from, @from], [theirs.reload.listable, review.reload.reviewable]
          end

          test "an applied verdict is a no-op" do
            item = UserListItem.create!(user_list: list(:read), listable: @from)
            verdict = guess_verdict(item_type: "UserListItem", item_id: item.id)
            verdict.update_columns(applied_at: Time.current)

            assert_equal :noop, Guess.call(verdict: verdict).data[:outcome]
            assert_equal @from, item.reload.listable
          end

          test "a favorites item reports the follow-up" do
            item = UserListItem.create!(user_list: list(:favorites), listable: @from)

            result = Guess.call(verdict: guess_verdict(item_type: "UserListItem", item_id: item.id))

            assert_includes result.data[:follow_ups], :user_favorites
          end
        end
      end
    end
  end
end
