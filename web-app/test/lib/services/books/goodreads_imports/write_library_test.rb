require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class WriteLibraryTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "writer@example.com", role: :user, email_verified: false)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :writing, created_at: Time.zone.local(2026, 9, 1, 12))
          @book = books_books(:war_and_peace)
          @other = books_books(:got)
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
        end

        def list(type)
          ::Books::UserList.find_by!(user: @user, list_type: type)
        end

        def custom(name)
          ::Books::UserList.custom.find_by!(user: @user, name: name)
        end

        # A row on an edition resolved to `book`.
        def row(book, number: @import.rows.count + 1, **attributes)
          edition = goodreads_edition(title: "#{book.title} #{number}", book: book, resolution: :matched, resolved_at: Time.current)
          @import.rows.create!({row_number: number, goodreads_edition: edition, exclusive_shelf: "read"}.merge(attributes))
        end

        def items(user_list)
          user_list.user_list_items.reload.map { |item| [item.listable_id, item.position] }
        end

        test "exclusive shelves map to the default lists" do
          row(@book, exclusive_shelf: "read", date_read: Date.new(2024, 5, 3))
          row(@other, exclusive_shelf: "to-read")

          WriteLibrary.call(import: @import)

          read_item = list(:read).user_list_items.sole
          assert_equal [@book.id, Date.new(2024, 5, 3)], [read_item.listable_id, read_item.completed_on]
          assert_equal [@other.id], list(:want_to_read).user_list_items.map(&:listable_id)
        end

        test "a read book with no Date Read is never dated today" do
          row(@book, exclusive_shelf: "read", date_read: nil)

          WriteLibrary.call(import: @import)

          assert_nil list(:read).user_list_items.sole.completed_on
        end

        test "currently-reading goes to reading" do
          row(@book, exclusive_shelf: "currently-reading")

          WriteLibrary.call(import: @import)

          assert_equal [@book.id], list(:reading).user_list_items.map(&:listable_id)
        end

        test "reading a book removes it from the reading list" do
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          list(:reading).user_list_items.create!(listable: @book)
          row(@book, exclusive_shelf: "read")

          WriteLibrary.call(import: @import)

          assert_empty list(:reading).user_list_items.reload
          assert_equal [@book.id], list(:read).user_list_items.map(&:listable_id)
        end

        test "read wins over currently-reading for the same book" do
          row(@book, exclusive_shelf: "currently-reading")
          row(@book, exclusive_shelf: "read", date_read: Date.new(2023, 1, 2))
          row(@book, exclusive_shelf: "read", date_read: Date.new(2024, 6, 7))

          WriteLibrary.call(import: @import)

          assert_empty list(:reading).user_list_items
          assert_equal Date.new(2024, 6, 7), list(:read).user_list_items.sole.completed_on
        end

        test "other shelves become custom lists, matched case-insensitively, with hyphens as spaces" do
          ::Books::UserList.create!(user: @user, list_type: :custom, name: "Science Fiction")
          row(@book, exclusive_shelf: "read", shelves: %w[science-fiction did-not-finish read])

          WriteLibrary.call(import: @import)

          assert_equal [@book.id], custom("Science Fiction").user_list_items.map(&:listable_id)
          assert_equal [@book.id], custom("did not finish").user_list_items.map(&:listable_id)
          assert_equal 1, ::Books::UserList.custom.where(user: @user).where("lower(name) = ?", "science fiction").count
        end

        test "a custom exclusive shelf becomes a custom list" do
          row(@book, exclusive_shelf: "abandoned")

          WriteLibrary.call(import: @import)

          assert_equal [@book.id], custom("abandoned").user_list_items.map(&:listable_id)
        end

        test "a favorites shelf is a custom list, never the favorites list" do
          row(@book, exclusive_shelf: "read", shelves: %w[favorites])

          WriteLibrary.call(import: @import)

          assert_equal [@book.id], custom("favorites").user_list_items.map(&:listable_id)
          assert_empty list(:favorites).user_list_items
        end

        test "new items follow shelf positions and append after existing items" do
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          kept = books_books(:crime_and_punishment)
          list(:want_to_read).user_list_items.create!(listable: kept)
          row(@book, exclusive_shelf: "to-read", shelf_positions: {"to-read" => 9})
          row(@other, exclusive_shelf: "to-read", shelf_positions: {"to-read" => 2})

          WriteLibrary.call(import: @import)

          assert_equal [[kept.id, 1], [@other.id, 2], [@book.id, 3]], items(list(:want_to_read)).sort_by(&:last)
        end

        test "a new item's created_at is Date Added, else the import time" do
          row(@book, exclusive_shelf: "to-read", date_added: Date.new(2020, 3, 4))
          row(@other, exclusive_shelf: "to-read")

          WriteLibrary.call(import: @import)

          created = list(:want_to_read).user_list_items.to_h { |item| [item.listable_id, item.created_at] }
          assert_equal Date.new(2020, 3, 4), created[@book.id].to_date
          assert_equal @import.created_at, created[@other.id]
        end

        test "an existing item is not moved; only a blank completed_on is filled" do
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          dated = list(:read).user_list_items.create!(listable: @other, completed_on: Date.new(2019, 1, 1))
          blank = list(:read).user_list_items.create!(listable: @book)
          row(@other, exclusive_shelf: "read", date_read: Date.new(2024, 1, 1))
          row(@book, exclusive_shelf: "read", date_read: Date.new(2024, 2, 2))

          WriteLibrary.call(import: @import)

          assert_equal [Date.new(2019, 1, 1), 1], [dated.reload.completed_on, dated.position]
          assert_equal [Date.new(2024, 2, 2), 2], [blank.reload.completed_on, blank.position]
        end

        test "a row records the list items it wrote" do
          written = row(@book, exclusive_shelf: "read", shelves: %w[classics])

          WriteLibrary.call(import: @import)

          ids = ::UserListItem.where(listable: @book, user_list: ::Books::UserList.where(user: @user)).pluck(:id)
          assert_equal ids.sort, written.reload.applied["list_item_ids"].sort
          assert written.applied?
        end

        test "running the same import twice changes nothing" do
          row(@book, exclusive_shelf: "read", date_read: Date.new(2024, 5, 3), shelves: %w[classics])
          WriteLibrary.call(import: @import)
          @import.update!(status: :complete)
          before = ::UserListItem.where(user_list: ::Books::UserList.where(user: @user)).order(:id)
            .pluck(:id, :user_list_id, :position, :completed_on)

          again = ::Books::GoodreadsImport.create!(user: @user, status: :writing)
          edition = @import.rows.first.goodreads_edition
          again.rows.create!(row_number: 1, goodreads_edition: edition, exclusive_shelf: "read",
            date_read: Date.new(2024, 5, 3), shelves: %w[classics])
          WriteLibrary.call(import: again)

          assert_equal before, ::UserListItem.where(user_list: ::Books::UserList.where(user: @user)).order(:id)
            .pluck(:id, :user_list_id, :position, :completed_on)
          assert_equal ["skipped", WriteLibrary::SKIPPED_DETAIL], [again.rows.sole.outcome, again.rows.sole.outcome_detail]
          assert_equal 1, again.reload.skipped_count
        end

        test "a parked edition's rows are parked; an unresolved one's are failed with its error" do
          parked = goodreads_edition(title: "Invented", resolution: :parked, verification: :not_found, resolved_at: Time.current)
          unresolved = goodreads_edition(title: "Broken")
          parked_row = @import.rows.create!(row_number: 1, goodreads_edition: parked, exclusive_shelf: "read")
          failed_row = @import.rows.create!(row_number: 2, goodreads_edition: unresolved, exclusive_shelf: "read",
            error: "resolution failed: Timeout")

          WriteLibrary.call(import: @import)

          assert_equal ["parked", "not found on Goodreads"], [parked_row.reload.outcome, parked_row.outcome_detail]
          assert_equal ["failed", "resolution failed: Timeout"], [failed_row.reload.outcome, failed_row.error]
        end

        test "a completion date purges the user's goal pages" do
          ::Services::Books::ReadingGoals::DestructionInvalidator.expects(:for_user).with(user: @user).returns(["https://b/reading_goals/1"])
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", ["https://b/reading_goals/1"])
          row(@book, exclusive_shelf: "read", date_read: Date.new(2024, 5, 3))

          WriteLibrary.call(import: @import)
        end

        test "no completion date purges nothing" do
          ::Services::Books::ReadingGoals::DestructionInvalidator.expects(:for_user).never
          row(@book, exclusive_shelf: "to-read")

          WriteLibrary.call(import: @import)
        end

        test "a rating with text becomes a review, Goodreads breaks as newlines" do
          winner = row(@book, rating: 4, review_body: "Long.<br/><br/>Worth it.", date_read: Date.new(2024, 5, 3))

          WriteLibrary.call(import: @import)

          review = ::Review.find_by!(user: @user, reviewable: @book)
          assert_equal [4, "Long.\n\nWorth it."], [review.rating, review.body]
          assert_equal Date.new(2024, 5, 3), review.created_at.to_date
          assert_equal review.id, winner.reload.applied["review_id"]
        end

        test "rating 0 with text is an unrated review; rating 0 and no text is nothing" do
          row(@book, rating: 0, review_body: "No stars from me.")
          row(@other, rating: 0, review_body: nil)

          WriteLibrary.call(import: @import)

          assert_nil ::Review.find_by!(user: @user, reviewable: @book).rating
          assert_not ::Review.exists?(user: @user, reviewable: @other)
        end

        test "an existing review is left untouched" do
          existing = ::Review.create!(user: @user, reviewable: @book, rating: 2, body: "Mine.")
          row(@book, rating: 5, review_body: "Imported.")

          WriteLibrary.call(import: @import)

          assert_equal [2, "Mine."], [existing.reload.rating, existing.body]
        end

        test "two rows for one book: the rated row, then the latest read, then the lowest row number wins" do
          row(@book, number: 1, rating: 0, review_body: "Text only.", date_read: Date.new(2025, 1, 1))
          row(@book, number: 2, rating: 3, review_body: "Older.", date_read: Date.new(2020, 1, 1))
          row(@book, number: 3, rating: 5, review_body: "Newer.", date_read: Date.new(2022, 1, 1))
          row(@other, number: 4, rating: 4, review_body: "First.")
          row(@other, number: 5, rating: 2, review_body: "Second.")

          WriteLibrary.call(import: @import)

          assert_equal "Newer.", ::Review.find_by!(user: @user, reviewable: @book).body
          assert_equal "First.", ::Review.find_by!(user: @user, reviewable: @other).body
        end

        test "a review that fails validation is not written; the row says why and keeps its list items" do
          long = row(@book, rating: 5, review_body: "x" * (::Review::MAX_BODY_LENGTH + 1))

          WriteLibrary.call(import: @import)

          assert_not ::Review.exists?(user: @user, reviewable: @book)
          assert_match(/review not imported/, long.reload.error)
          assert long.applied?
        end

        test "summaries are recalculated once per reviewed book, not per review callback" do
          row(@book, rating: 4)
          row(@book, rating: 2)
          ::Services::Reviews::SummaryRecalculator.expects(:recalculate).with("Books::Book", @book.id).once

          WriteLibrary.call(import: @import)
        end

        test "a row that only wrote a review is applied" do
          ::Services::UserLists::EnsureDefaults.call(user: @user, domain: :books, existing: [])
          list(:read).user_list_items.create!(listable: @book)
          reviewed = row(@book, rating: 4)

          WriteLibrary.call(import: @import)

          assert reviewed.reload.applied?
          assert_equal [], Array(reviewed.applied["list_item_ids"])
        end
      end
    end
  end
end
