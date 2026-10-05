require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      module Apply
        class RelinkTest < ActiveSupport::TestCase
          setup do
            @user = users(:regular_user)
            @read = user_lists(:regular_user_books_read)
            @from = books_books(:war_and_peace)
            @to = books_books(:of_mice_and_men)
            UserListItem.where(listable: [@from, @to]).delete_all
            Review.where(reviewable: [@from, @to]).delete_all
          end

          def verdict(user_id: @user.id, from: @from, to: @to, strip: [], goodreads_book_id: 1)
            from_id = from.is_a?(Integer) ? from : from.id
            to_id = to.is_a?(Integer) ? to : to.id
            ::Books::RepairVerdict.create!(kind: :relink, subject_key: "user:#{user_id}:book:#{from_id}:goodreads:#{goodreads_book_id}",
              decided_by: :ai, status: :approved,
              payload: {"user_id" => user_id, "from_book_id" => from_id, "to_book_id" => to_id, "goodreads_book_id" => goodreads_book_id,
                        "strip_identifiers" => strip, "stamp_identifiers" => strip})
          end

          # A book merged into another and gone, as Books::Book::Merger leaves it:
          # the pair is marked merged.
          def merged_away(into:)
            gone = ::Books::Book.create!(title: "Merged Away #{SecureRandom.hex(3)}")
            ::Services::DuplicateCandidates::Flag.call(item_type: "Books::Book", ids: [gone.id, into.id], source: :ai)
            ::DuplicateCandidate.where(item_type: "Books::Book", item_a_id: [gone.id, into.id].min, item_b_id: [gone.id, into.id].max)
              .update_all(status: ::DuplicateCandidate.statuses[:merged])
            id = gone.id
            gone.destroy!
            id
          end

          test "a destination merged away earlier follows the merge to the book that survived" do
            item = UserListItem.create!(user_list: @read, listable: @from)

            result = Relink.call(verdict: verdict(to: merged_away(into: @to)))

            assert_equal :applied, result.data[:outcome]
            assert_equal @to, item.reload.listable
          end

          test "a destination merged by an approved merge_books verdict follows it too" do
            gone = ::Books::Book.create!(title: "Merged By Verdict")
            ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "books:x", decided_by: :rule, status: :approved,
              payload: {"source_id" => gone.id, "target_id" => @to.id})
            gone_id = gone.id
            gone.destroy!
            item = UserListItem.create!(user_list: @read, listable: @from)

            Relink.call(verdict: verdict(to: gone_id))

            assert_equal @to, item.reload.listable
          end

          test "a source merged away earlier is followed, and a source merged into the destination is nothing to do" do
            survivor = ::Books::Book.create!(title: "Survivor")
            item = UserListItem.create!(user_list: @read, listable: survivor)

            Relink.call(verdict: verdict(from: merged_away(into: survivor)))
            assert_equal @to, item.reload.listable

            result = Relink.call(verdict: verdict(from: merged_away(into: @to), goodreads_book_id: 2))
            assert_equal :noop, result.data[:outcome]
          end

          test "two approved relinks off one book leave the user with both destinations" do
            second_to = books_books(:cannery_row)
            UserListItem.where(listable: second_to).delete_all
            UserListItem.create!(user_list: @read, listable: @from)
            first = verdict(goodreads_book_id: 1)
            second = verdict(to: second_to, goodreads_book_id: 2)

            Relink.call(verdict: first)
            Relink.call(verdict: second)

            assert_equal [@to.id, second_to.id].sort, UserListItem.where(user_list: @read, listable: [@from, @to, second_to]).pluck(:listable_id).sort
          end

          test "a moved favorite asks for the favorites rebuild and the rankings it feeds" do
            UserListItem.create!(user_list: user_lists(:regular_user_books_favorites), listable: @from)

            result = Relink.call(verdict: verdict)

            assert_equal [:user_favorites], result.data[:follow_ups]
            default = ::Books::RankingConfiguration.default_primary
            assert_includes result.data[:reweigh_configuration_ids], default.id if default
          end

          test "a moved read asks for no favorites follow-up" do
            UserListItem.create!(user_list: @read, listable: @from)

            assert_empty Array(Relink.call(verdict: verdict).data[:follow_ups])
          end

          test "a copied completed read purges the goal pages its new count changes" do
            ::Identifier.create!(identifiable: @from, identifier_type: :books_work_goodreads_id, value: "111")
            import = ::Books::GoodreadsImport.create!(user: @user, source: :legacy_replay, status: :complete, legacy_import_id: 79)
            agreeing = ::Books::GoodreadsEdition.create!(goodreads_book_id: 111, signature: "s111", title: "War and Peace", primary_author: "Leo Tolstoy")
            import.rows.create!(row_number: 1, goodreads_edition: agreeing)
            UserListItem.create!(user_list: @read, listable: @from, completed_on: Date.new(2025, 3, 1))
            ::Services::Books::ReadingGoals::CompletionChangeInvalidator.expects(:call)
              .with(user: @user, old_completed_on: nil, new_completed_on: Date.new(2025, 3, 1)).once

            Relink.call(verdict: verdict)
          end

          test "moves the user's list items and review from the wrong book to the right one" do
            item = UserListItem.create!(user_list: @read, listable: @from, completed_on: Date.new(2025, 3, 1))
            review = Review.create!(user: @user, reviewable: @from, rating: 4)

            result = Relink.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_equal @to, item.reload.listable
            assert_equal @to, review.reload.reviewable
          end

          test "on a list holding both books, keeps the right one's item and fills its blank date from the wrong one's" do
            UserListItem.create!(user_list: @read, listable: @from, completed_on: Date.new(2025, 3, 1))
            kept = UserListItem.create!(user_list: @read, listable: @to)

            Relink.call(verdict: verdict)

            assert_equal [kept.id], UserListItem.where(user_list: @read, listable: [@from, @to]).pluck(:id)
            assert_equal Date.new(2025, 3, 1), kept.reload.completed_on
          end

          test "keeps a review the user already wrote on the right book" do
            Review.create!(user: @user, reviewable: @from, rating: 2)
            kept = Review.create!(user: @user, reviewable: @to, rating: 5)

            Relink.call(verdict: verdict)

            assert_equal [kept.id], Review.where(user: @user, reviewable: [@from, @to]).pluck(:id)
          end

          test "another user's items on the wrong book stay where they are" do
            other_list = ::Books::UserList.create!(user: users(:editor_user), name: "Shelf", list_type: :custom)
            other = UserListItem.create!(user_list: other_list, listable: @from)
            UserListItem.create!(user_list: @read, listable: @from)

            Relink.call(verdict: verdict)

            assert_equal @from, other.reload.listable
          end

          test "moves the row's identifiers when the payload says legacy's identifier was wrong" do
            ::Identifier.create!(identifiable: @from, identifier_type: :books_work_goodreads_id, value: "777")
            UserListItem.create!(user_list: @read, listable: @from)

            Relink.call(verdict: verdict(strip: [["books_work_goodreads_id", "777"]]))

            refute @from.identifiers.exists?(identifier_type: :books_work_goodreads_id, value: "777")
            assert @to.identifiers.exists?(identifier_type: :books_work_goodreads_id, value: "777")
          end

          test "when another of the user's rows still names the wrong book, the right one is added and the wrong one kept" do
            ::Identifier.create!(identifiable: @from, identifier_type: :books_work_goodreads_id, value: "111")
            import = ::Books::GoodreadsImport.create!(user: @user, source: :legacy_replay, status: :complete, legacy_import_id: 77)
            agreeing = ::Books::GoodreadsEdition.create!(goodreads_book_id: 111, signature: "s111", title: "War and Peace", primary_author: "Leo Tolstoy")
            import.rows.create!(row_number: 1, goodreads_edition: agreeing)
            item = UserListItem.create!(user_list: @read, listable: @from, completed_on: Date.new(2025, 3, 1))
            review = Review.create!(user: @user, reviewable: @from, rating: 4)

            relink = verdict
            result = Relink.call(verdict: relink)

            assert_equal :applied, result.data[:outcome]
            assert_equal @from, item.reload.listable
            assert_equal Date.new(2025, 3, 1), UserListItem.find_by!(user_list: @read, listable: @to).completed_on
            assert_equal @from, review.reload.reviewable
            assert_equal :noop, Relink.call(verdict: relink).data[:outcome]
          end

          test "applying twice does nothing the second time" do
            UserListItem.create!(user_list: @read, listable: @from)
            relink = verdict
            Relink.call(verdict: relink)

            assert_equal :noop, Relink.call(verdict: relink).data[:outcome]
          end

          test "a deleted user, or either book gone, is a no-op with a reason" do
            assert_equal "user 0 no longer exists", Relink.call(verdict: verdict(user_id: 0)).data[:reason]

            gone = verdict
            gone.payload["to_book_id"] = 0
            assert_equal "book 0 no longer exists", Relink.call(verdict: gone).data[:reason]
          end
        end
      end
    end
  end
end
