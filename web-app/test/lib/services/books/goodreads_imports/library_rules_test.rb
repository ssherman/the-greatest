require "test_helper"

module Services
  module Books
    module GoodreadsImports
      class LibraryRulesTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @user = User.create!(email: "rules@example.com", role: :user, email_verified: false)
          @import = ::Books::GoodreadsImport.create!(user: @user, status: :complete, source: :legacy_replay, created_at: Time.zone.local(2026, 9, 1, 12))
          @book = books_books(:war_and_peace)
          @fallback = Time.zone.local(2026, 9, 1, 12)
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)
        end

        def list(type)
          ::Books::UserList.find_by!(user: @user, list_type: type)
        end

        def row(**attributes)
          number = @import.rows.count + 1
          edition = goodreads_edition(title: "Rules #{number}", book: @book, resolution: :matched, resolved_at: Time.current)
          @import.rows.create!({row_number: number, goodreads_edition: edition, exclusive_shelf: "read"}.merge(attributes))
        end

        def write(row)
          LibraryRules.write_row(user: @user, row: row, book: @book, fallback_created_at: @fallback)
        end

        test "a read row lands on the read list dated from Date Read" do
          result = write(row(date_read: Date.new(2024, 5, 3), date_added: Date.new(2024, 1, 2)))

          item = list(:read).user_list_items.sole
          assert_equal [item.id], result[:list_item_ids]
          assert_equal [@book.id, Date.new(2024, 5, 3)], [item.listable_id, item.completed_on]
          assert_equal Date.new(2024, 1, 2), item.created_at.to_date
        end

        test "a to-read row lands on want to read and falls back to the given created_at" do
          write(row(exclusive_shelf: "to-read"))

          item = list(:want_to_read).user_list_items.sole
          assert_equal @fallback, item.created_at
          assert_nil item.completed_on
        end

        test "a custom shelf lands on a custom list named after it, matched case-insensitively" do
          existing = ::Books::UserList.create!(user: @user, list_type: :custom, name: "Sci Fi Picks")

          write(row(exclusive_shelf: "to-read", shelves: ["sci-fi-picks", "brand-new"]))

          assert_equal [@book.id], existing.user_list_items.map(&:listable_id)
          assert_equal [@book.id], ::Books::UserList.custom.find_by!(user: @user, name: "brand new").user_list_items.map(&:listable_id)
          assert_equal 1, ::Books::UserList.custom.where(user: @user).where("lower(name) = 'sci fi picks'").count
        end

        test "a read row removes the reading item and never adds to reading" do
          reading = list(:reading)
          reading.user_list_items.create!(listable: @book, position: 1)

          write(row(exclusive_shelf: "read", shelves: ["currently-reading"]))

          assert_empty reading.user_list_items.reload
        end

        test "an existing item only gets a blank completed_on filled" do
          write(row(date_read: nil))
          item = list(:read).user_list_items.sole
          write(row(date_read: Date.new(2024, 5, 3)))
          assert_equal Date.new(2024, 5, 3), item.reload.completed_on

          write(row(date_read: Date.new(2025, 1, 1)))
          assert_equal Date.new(2024, 5, 3), item.reload.completed_on
        end

        test "a new item goes after the list's last position" do
          other = books_books(:got)
          list(:read).user_list_items.create!(listable: other, position: 7)

          write(row)

          assert_equal [7, 8], list(:read).user_list_items.order(:position).map(&:position)
        end

        test "writing the same row twice changes nothing" do
          row = row(date_read: Date.new(2024, 5, 3), rating: 4, review_body: "Good")
          first = write(row)
          second = write(row)

          assert_equal first[:list_item_ids], second[:list_item_ids]
          assert_nil second[:review_id]
          assert_equal 1, list(:read).user_list_items.count
          assert_equal 1, ::Review.where(user: @user, reviewable: @book).count
        end

        test "a row with a review writes it once and recalculates the summary" do
          ::Services::Reviews::SummaryRecalculator.expects(:recalculate).with("Books::Book", @book.id).once

          result = write(row(rating: 4, review_body: "Line one<br>Line two", date_read: Date.new(2024, 5, 3)))

          review = ::Review.find(result[:review_id])
          assert_equal [4, "Line one\nLine two", Date.new(2024, 5, 3)], [review.rating.to_i, review.body, review.created_at.to_date]
        end

        test "review: false writes the list items and no review" do
          result = LibraryRules.write_row(user: @user, row: row(rating: 4, review_body: "Good"), book: @book, fallback_created_at: @fallback, review: false)

          assert_nil result[:review_id]
          assert_equal 1, result[:list_item_ids].size
          assert_not ::Review.exists?(user: @user, reviewable: @book)
        end

        test "rating 0 with text is an unrated review and rating 0 without text is none" do
          result = write(row(rating: 0, review_body: "Just words"))
          assert_nil ::Review.find(result[:review_id]).rating

          ::Review.where(user: @user).delete_all
          assert_nil write(row(rating: 0, review_body: nil))[:review_id]
        end

        test "an existing review by the user is left alone" do
          ::Review.create!(user: @user, reviewable: @book, rating: 2, body: "Mine")

          assert_nil write(row(rating: 5, review_body: "Theirs"))[:review_id]
          assert_equal "Mine", ::Review.find_by!(user: @user, reviewable: @book).body
        end
      end
    end
  end
end
