# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      class DecideGuessesTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @other = users(:editor_user)
          @mixed = ::Books::Book.create!(title: "Lump")
          @dest_a = ::Books::Book.create!(title: "Dest A")
          @dest_b = ::Books::Book.create!(title: "Dest B")
          @list = ::Books::UserList.create!(user: @user, name: "Shelf", list_type: :custom)
          @other_list = ::Books::UserList.create!(user: @other, name: "Shelf", list_type: :custom)
          @hand_added = UserListItem.create!(user_list: @list, listable: @mixed)
          @explained = UserListItem.create!(user_list: @other_list, listable: @mixed)
          @review = Review.create!(user: @user, reviewable: @mixed, rating: 4, title: "T", body: "B")
          @import = ::Books::GoodreadsImport.create!(user: @other, source: :legacy_replay, status: :complete, legacy_import_id: 71)
          @keys = [[@import.id, 1], [@import.id, 2], [@import.id, 3]]
          @mixed_verdict = verdict(:reimport_mixed, "reimport:book:#{@mixed.id}",
            {"book_id" => @mixed.id, "row_keys" => @keys, "archive" => {}})
        end

        test "an item no row explains gets a guess to the most-read destination" do
          row_verdict(1, @dest_a)
          row_verdict(2, @dest_b)
          row_verdict(3, @dest_b)

          result = DecideGuesses.call(mixed_verdict: @mixed_verdict)

          assert_equal [:decided, 2, @dest_b.id], result.data.values_at(:outcome, :guesses, :redirect_to_book_id)
          guess = ::Books::RepairVerdict.reimport_guess.find_by!(subject_key: "reimport:guess:UserListItem:#{@hand_added.id}")
          assert_equal [@hand_added.id, @user.id, @mixed.id, @dest_b.id, true],
            guess.payload.values_at("item_id", "user_id", "from_book_id", "to_book_id", "guess")
          assert_predicate guess, :approved?
          assert_predicate guess, :decided_by_rule?
          assert ::Books::RepairVerdict.reimport_guess.exists?(subject_key: "reimport:guess:Review:#{@review.id}")
          assert_equal @dest_b.id, @mixed_verdict.reload.payload["redirect_to_book_id"]
        end

        test "an item a row explains gets no guess" do
          row_verdict(1, @dest_a)
          row_verdict(2, @dest_a)
          row_verdict(3, @dest_a)

          DecideGuesses.call(mixed_verdict: @mixed_verdict)

          refute ::Books::RepairVerdict.reimport_guess.exists?(subject_key: "reimport:guess:UserListItem:#{@explained.id}")
        end

        test "superseded keeps do not count and ties go to the lowest book id" do
          row_verdict(1, @dest_b)
          row_verdict(2, @dest_a)
          row_verdict(3, @dest_b, superseded_by: "reimport:row:#{@import.id}:9")

          assert_equal [@dest_a.id, @dest_b.id].min, DecideGuesses.call(mixed_verdict: @mixed_verdict).data[:redirect_to_book_id]
        end

        test "a user whose only rows on the book are superseded keeps still has an unexplained entry" do
          row_verdict(1, @dest_a)
          row_verdict(2, @dest_a)
          verdict(:reimport_row, "reimport:row:#{@import.id}:3",
            {"user_id" => @user.id, "action" => "keep", "from_book_id" => @mixed.id, "to_book_id" => @dest_a.id,
             "superseded_by" => "reimport:row:#{@import.id}:9"})

          DecideGuesses.call(mixed_verdict: @mixed_verdict)

          assert ::Books::RepairVerdict.reimport_guess.exists?(subject_key: "reimport:guess:UserListItem:#{@hand_added.id}")
        end

        test "waits while any row is undecided" do
          row_verdict(1, @dest_a)
          row_verdict(2, @dest_a)

          result = DecideGuesses.call(mixed_verdict: @mixed_verdict)

          assert_equal :waiting, result.data[:outcome]
          assert_equal 0, ::Books::RepairVerdict.reimport_guess.count
          assert_not @mixed_verdict.reload.payload.key?("redirect_to_book_id")
        end

        test "a rejected row verdict counts as undecided" do
          row_verdict(1, @dest_a)
          row_verdict(2, @dest_a)
          row_verdict(3, @dest_a, status: :rejected)

          assert_equal :waiting, DecideGuesses.call(mixed_verdict: @mixed_verdict).data[:outcome]
        end

        test "skips a mixed verdict that is not approved" do
          @mixed_verdict.update!(status: :rejected)

          assert_equal :skipped, DecideGuesses.call(mixed_verdict: @mixed_verdict).data[:outcome]
        end

        test "a re-run is idempotent" do
          3.times { |i| row_verdict(i + 1, @dest_a) }
          DecideGuesses.call(mixed_verdict: @mixed_verdict)

          assert_no_difference -> { ::Books::RepairVerdict.count } do
            assert_equal 2, DecideGuesses.call(mixed_verdict: @mixed_verdict.reload).data[:guesses]
          end
        end

        private

        def verdict(kind, key, payload, status: :approved)
          ::Books::RepairVerdict.create!(kind: kind, subject_key: key, payload: payload, decided_by: :rule, status: status)
        end

        def row_verdict(number, destination, superseded_by: nil, status: :approved)
          verdict(:reimport_row, "reimport:row:#{@import.id}:#{number}",
            {"user_id" => @other.id, "action" => superseded_by ? "keep" : "move", "from_book_id" => @mixed.id,
             "to_book_id" => destination.id, "superseded_by" => superseded_by}, status: status)
        end
      end
    end
  end
end
