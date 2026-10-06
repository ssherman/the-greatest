require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class RevertTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
          @user = User.create!(email: "revert@example.com", role: :user, email_verified: false)
          @reviewer = users(:admin_user)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :complete)
          @read = ::Books::UserList.find_by!(user: @user, list_type: :read)
          @kept = @read.user_list_items.create!(listable: books_books(:crime_and_punishment))
          @matched = books_books(:war_and_peace)
          @author = ::Books::Author.create!(name: "Revert Author", provisional: true)
          @created = ::Books::Book.create!(title: "Revert Created Book", provisional: true)
          ::Books::BookAuthor.create!(book: @created, author: @author, position: 1)
          [@created, @author].each { |record| @import.records.create!(record: record, action: :created) }
          @created_edition = goodreads_edition(title: "Revert Created Book", book: @created, resolution: :created, resolved_at: Time.current)
          @items = [@matched, @created].map { |book| @read.user_list_items.create!(listable: book) }
          @review = ::Review.create!(user: @user, reviewable: @matched, rating: 4)
          @import.rows.create!(row_number: 1, goodreads_edition: goodreads_edition(title: "Revert Matched", book: @matched,
            resolution: :matched, resolved_at: Time.current), outcome: :applied,
            applied: {"list_item_ids" => [@items.first.id], "review_id" => @review.id})
          @import.rows.create!(row_number: 2, goodreads_edition: @created_edition, outcome: :applied,
            applied: {"list_item_ids" => [@items.last.id]})
        end

        test "removes exactly what the import wrote and the provisional records nothing else uses" do
          result = Revert.call(import: @import, reviewer: @reviewer)

          assert result.success?
          assert_equal [@kept.id], @read.user_list_items.reload.map(&:id)
          assert_equal 1, @kept.reload.position
          assert_not ::Review.exists?(@review.id)
          assert_not ::Books::Book.exists?(@created.id)
          assert_not ::Books::Author.exists?(@author.id)
          assert ::Books::Book.exists?(@matched.id)
          assert_equal ["rejected", @reviewer.id], [@import.reload.review_status, @import.reviewed_by_id]
          assert_empty @import.rows.where("applied != '{}'::jsonb")
        end

        test "a provisional book another import's rows name is kept" do
          other = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :complete)
          other.rows.create!(row_number: 1, goodreads_edition: @created_edition)

          Revert.call(import: @import, reviewer: @reviewer)

          assert ::Books::Book.exists?(@created.id)
          assert_not ::UserListItem.exists?(@items.last.id)
        end

        test "editions waiting on Goodreads for the import are released from it" do
          waiting = goodreads_edition(title: "Revert Waiting Book", verification: :pending, pending_import: @import)

          Revert.call(import: @import, reviewer: @reviewer)

          assert_nil waiting.reload.pending_import_id
        end

        test "a book two rejected imports share is deleted by the second rejection" do
          other = ::Books::GoodreadsImport.create!(user: users(:regular_user), status: :complete)
          other.rows.create!(row_number: 1, goodreads_edition: @created_edition)
          Revert.call(import: other, reviewer: @reviewer)

          Revert.call(import: @import, reviewer: @reviewer)

          assert_not ::Books::Book.exists?(@created.id)
        end

        test "identifiers the import stamped on an existing book are removed" do
          stamped = ::Identifier.create!(identifiable: @matched, identifier_type: :books_work_goodreads_id, value: "999123")
          @import.records.create!(record: stamped, action: :stamped)

          Revert.call(import: @import, reviewer: @reviewer)

          assert_not ::Identifier.exists?(stamped.id)
        end

        test "summaries are recalculated for reviewed books and goal pages purged" do
          ::Services::Reviews::SummaryRecalculator.expects(:recalculate).with("Books::Book", @matched.id)
          ::Services::Books::ReadingGoals::DestructionInvalidator.expects(:for_user).with(user: @user).returns(["u"])
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", ["u"])

          Revert.call(import: @import, reviewer: @reviewer)
        end

        test "a stuck import is failed as it is rejected, freeing the member to upload again" do
          @import.update!(status: :writing, started_at: 3.hours.ago)

          assert Revert.call(import: @import, reviewer: @reviewer).success?
          assert @import.reload.failed?
        end

        test "an import still running, a replay import, or one already rejected is refused" do
          @import.update!(status: :resolving, started_at: Time.current)
          assert_not Revert.call(import: @import, reviewer: @reviewer).success?

          @import.update!(status: :complete, review_status: :rejected)
          assert_not Revert.call(import: @import, reviewer: @reviewer).success?

          @import.update!(review_status: :pending, source: :legacy_replay, legacy_import_id: 7002)
          assert_not Revert.call(import: @import, reviewer: @reviewer).success?
        end
      end
    end
  end
end
