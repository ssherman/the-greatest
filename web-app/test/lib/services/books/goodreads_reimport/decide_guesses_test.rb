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

        test "a book with entries but no CSV rows is kept, since nothing says where its readers belong" do
          @mixed_verdict.update_columns(payload: @mixed_verdict.payload.merge("row_keys" => []))

          result = DecideGuesses.call(mixed_verdict: @mixed_verdict)

          assert_equal :kept, result.data[:outcome]
          assert_equal [true, "no CSV rows"], @mixed_verdict.reload.payload.values_at("kept", "kept_reason")
          refute ::Books::RepairVerdict.reimport_guess.exists?
        end

        test "a book with no CSV rows and no entries is left for Apply::Mixed to delete" do
          @mixed_verdict.update_columns(payload: @mixed_verdict.payload.merge("row_keys" => []))
          [@hand_added, @explained, @review].each(&:destroy!)

          assert_equal :waiting, DecideGuesses.call(mixed_verdict: @mixed_verdict).data[:outcome]
          assert_nil @mixed_verdict.reload.payload["kept"]
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

        test "a row that keeps the mixed book keeps it: marked kept, no guesses, earlier guesses superseded" do
          earlier = verdict(:reimport_guess, "reimport:guess:UserListItem:#{@hand_added.id}",
            {"item_type" => "UserListItem", "item_id" => @hand_added.id, "from_book_id" => @mixed.id, "to_book_id" => @dest_a.id})
          unrelated = verdict(:reimport_guess, "reimport:guess:UserListItem:0",
            {"item_type" => "UserListItem", "item_id" => 0, "from_book_id" => @mixed.id + 1, "to_book_id" => @dest_a.id})
          applied = verdict(:reimport_guess, "reimport:guess:Review:0",
            {"item_type" => "Review", "item_id" => 0, "from_book_id" => @mixed.id, "to_book_id" => @dest_a.id})
          applied.update!(applied_at: Time.current)
          row_verdict(1, @dest_a)
          row_verdict(2, @mixed)
          row_verdict(3, @dest_a)

          result = DecideGuesses.call(mixed_verdict: @mixed_verdict)

          assert_equal [:kept, 0, nil], result.data.values_at(:outcome, :guesses, :redirect_to_book_id)
          payload = @mixed_verdict.reload.payload
          assert_equal true, payload["kept"]
          assert_not payload.key?("redirect_to_book_id")
          assert_not_nil earlier.reload.superseded_at
          assert_nil unrelated.reload.superseded_at
          assert_nil applied.reload.superseded_at
        end

        test "a superseded or rejected keep does not keep the mixed book" do
          row_verdict(1, @dest_a)
          row_verdict(2, @mixed, superseded_by: "reimport:row:#{@import.id}:9")
          row_verdict(3, @dest_a)
          verdict(:reimport_row, "reimport:row:99:1", {"user_id" => @other.id, "action" => "keep", "to_book_id" => @mixed.id}, status: :rejected)

          result = DecideGuesses.call(mixed_verdict: @mixed_verdict)

          assert_equal :decided, result.data[:outcome]
          assert_not @mixed_verdict.reload.payload.key?("kept")
        end

        test "a reader's row from another book, or an unrejected match, that heads to the mixed book keeps it" do
          row_verdict(1, @dest_a)
          row_verdict(2, @dest_a)
          row_verdict(3, @dest_a)
          outside = verdict(:reimport_row, "reimport:row:98:1",
            {"user_id" => @user.id, "action" => "move", "from_book_id" => @dest_b.id, "to_book_id" => @mixed.id}, status: :proposed)

          assert_equal :kept, DecideGuesses.call(mixed_verdict: @mixed_verdict).data[:outcome]

          outside.update!(status: :rejected)
          assert_equal :decided, DecideGuesses.call(mixed_verdict: @mixed_verdict).data[:outcome]

          verdict(:reimport_match, "reimport:edition:5", {"outcome" => "matched", "book_id" => @mixed.id})
          assert_equal :kept, DecideGuesses.call(mixed_verdict: @mixed_verdict).data[:outcome]
        end

        test "an applied verdict that was not kept is left alone" do
          row_verdict(1, @dest_a)
          row_verdict(2, @mixed)
          row_verdict(3, @dest_a)
          @mixed_verdict.update_columns(applied_at: Time.current,
            payload: @mixed_verdict.payload.merge("redirect_to_book_id" => @dest_a.id, "redirect_written" => true))

          assert_equal :skipped, DecideGuesses.call(mixed_verdict: @mixed_verdict).data[:outcome]
          assert_not @mixed_verdict.reload.payload.key?("kept")
        end

        test "flips back when no row keeps the book any more" do
          row_verdict(1, @dest_a)
          keep = row_verdict(2, @mixed)
          row_verdict(3, @dest_a)
          DecideGuesses.call(mixed_verdict: @mixed_verdict)
          guess_key = "reimport:guess:UserListItem:#{@hand_added.id}"
          earlier = ::Books::RepairVerdict.find_by(subject_key: guess_key)
          assert_nil earlier

          keep.update!(payload: keep.payload.merge("to_book_id" => @dest_a.id))
          result = DecideGuesses.call(mixed_verdict: @mixed_verdict)

          assert_equal :decided, result.data[:outcome]
          payload = @mixed_verdict.reload.payload
          assert_not payload.key?("kept")
          assert_equal @dest_a.id, payload["redirect_to_book_id"]
          assert ::Books::RepairVerdict.reimport_guess.current.exists?(subject_key: guess_key)
        end

        test "flipping back reopens a kept verdict that Apply closed" do
          row_verdict(1, @dest_a)
          keep = row_verdict(2, @mixed)
          row_verdict(3, @dest_a)
          DecideGuesses.call(mixed_verdict: @mixed_verdict)
          @mixed_verdict.update_columns(applied_at: Time.current, payload: @mixed_verdict.reload.payload.merge("closed_reason" => "kept: readers matched this book"))

          keep.update!(payload: keep.payload.merge("to_book_id" => @dest_a.id))
          DecideGuesses.call(mixed_verdict: @mixed_verdict)

          @mixed_verdict.reload
          assert_nil @mixed_verdict.applied_at
          assert_not @mixed_verdict.payload.key?("closed_reason")
        end

        test "a superseded guess is brought back by a flip back" do
          row_verdict(1, @dest_a)
          keep = row_verdict(2, @mixed)
          row_verdict(3, @dest_a)
          key = "reimport:guess:UserListItem:#{@hand_added.id}"
          verdict(:reimport_guess, key, {"item_type" => "UserListItem", "item_id" => @hand_added.id, "from_book_id" => @mixed.id, "to_book_id" => @dest_a.id})
          DecideGuesses.call(mixed_verdict: @mixed_verdict)
          assert_not_nil ::Books::RepairVerdict.find_by(subject_key: key).superseded_at

          keep.update!(payload: keep.payload.merge("to_book_id" => @dest_a.id))
          DecideGuesses.call(mixed_verdict: @mixed_verdict)

          assert_nil ::Books::RepairVerdict.find_by(subject_key: key).superseded_at
        end

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
