require "test_helper"

module Services
  module Books
    module BookSubmissions
      class RejectTest < ActiveSupport::TestCase
        include BookSubmissionReviewHelper
        include GoodreadsImportHelper

        setup do
          stub_review_side_effects
          @admin = users(:admin_user)
          @reader = users(:regular_user)
          @submission = lease(reviewable_submission(user: @reader))
          @book = @submission.book
          @author = @book.authors.first
          @sources = ["https://example.com/no-such-book"]
        end

        teardown { Current.reset }

        def reject(submission = @submission, via: "api", lease_token: TOKEN, note: "No record of it anywhere", sources: @sources, dry_run: false)
          Reject.call(submission: submission, user: @admin, via: via, lease_token: lease_token, note: note, sources: sources, dry_run: dry_run)
        end

        def other_reader = users(:editor_user)

        def custom_list(user)
          ::Books::UserList.create!(user: user, name: "Custom #{serial}", list_type: :custom)
        end

        test "deletes the book, the reader's items and the author left with no book, and stamps the row" do
          item = UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @book)

          result = reject

          assert_success result
          assert_not ::Books::Book.exists?(@book.id)
          assert_not UserListItem.exists?(item.id)
          assert_not ::Books::Author.exists?(@author.id)
          row = fresh(@submission)
          assert_equal ["rejected", nil, @admin.id, "api", "No record of it anywhere", @sources, nil],
            [row.review_status, row.book_id, row.reviewed_by_id, row.reviewed_via, row.review_note, row.review_sources, row.lease_token]
          assert_equal [@book.id, [@author.id]], [result.data[:book_id], result.data[:author_ids]]
        end

        test "a row still in progress is cancelled with the rejection" do
          @submission.update_columns(status: ::Books::BookSubmission.statuses[:looking_up])

          reject

          assert_equal ["cancelled", "rejected"], [fresh(@submission).status, fresh(@submission).review_status]
        end

        test "a book two readers submitted goes with both rows rejected and both items gone" do
          other = reviewable_submission(user: other_reader, book: @book, review_status: :not_needed)
          mine = UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @book)
          theirs = UserListItem.create!(user_list: custom_list(other_reader), listable: @book)
          Review.create!(user: other_reader, reviewable: @book, rating: 3)

          assert_success reject

          assert_equal ["rejected", "rejected"], [fresh(@submission).review_status, fresh(other).review_status]
          assert_equal "No record of it anywhere", fresh(other).review_note
          assert_equal @sources, fresh(other).review_sources
          assert_equal 0, UserListItem.where(id: [mine.id, theirs.id]).count
          assert_equal 0, Review.where(reviewable_type: "Books::Book", reviewable_id: @book.id).count
        end

        test "refused when another reader's list item uses the book" do
          UserListItem.create!(user_list: custom_list(other_reader), listable: @book)

          assert_failure reject, :invalid, "list item"
          assert ::Books::Book.exists?(@book.id)
          assert_equal "pending", fresh(@submission).review_status
        end

        test "refused when another reader's review uses the book" do
          Review.create!(user: other_reader, reviewable: @book, rating: 3)

          assert_failure reject, :invalid, "review"
          assert ::Books::Book.exists?(@book.id)
        end

        test "refused when a curated list holds the book" do
          ListItem.create!(list: lists(:books_list), listable: @book, position: 1)

          assert_failure reject, :invalid, "curated"
          assert ::Books::Book.exists?(@book.id)
        end

        test "refused when a Goodreads import row names the book" do
          import = ::Books::GoodreadsImport.create!(user: other_reader, status: :complete)
          edition = goodreads_edition(title: @book.title, book: @book, resolution: :created, resolved_at: Time.current)
          import.rows.create!(row_number: 1, goodreads_edition: edition)

          assert_failure reject, :invalid, "Goodreads"
          assert ::Books::Book.exists?(@book.id)
        end

        test "refused when a Goodreads import record names the book" do
          import = ::Books::GoodreadsImport.create!(user: other_reader, status: :complete)
          import.records.create!(record: @book, action: :created)

          assert_failure reject, :invalid, "Goodreads"
        end

        test "refused when the book is no longer provisional" do
          @book.update_columns(provisional: false)

          assert_failure reject, :conflict, "provisional"
          assert ::Books::Book.exists?(@book.id)
        end

        test "refused when no submission created the book" do
          @book.submissions.update_all(created_book: false)

          assert_failure reject, :invalid, "created"
          assert ::Books::Book.exists?(@book.id)
        end

        test "allowed after the submitter moved the book from Reading to Read and favorited it" do
          UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @book, completed_on: Date.current)
          UserListItem.create!(user_list: user_lists(:regular_user_books_favorites), listable: @book)
          ::Books::ReadingGoals::PurgeCachedPagesJob.unstub(:perform_async)
          ::Books::ReadingGoals::PurgeCachedPagesJob.stubs(:perform_async)

          assert_success reject
          assert_not ::Books::Book.exists?(@book.id)
          assert_equal 0, UserListItem.where(listable_type: "Books::Book", listable_id: @book.id).count
        end

        test "goal pages of readers who had it on Read are purged after the commit" do
          UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @book, completed_on: Date.current)
          ::Services::Books::ReadingGoals::DestructionInvalidator.stubs(:for_book).returns(["/goals/1"])
          ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", ["/goals/1"]).once

          assert_success reject
        end

        test "an author another book credits is kept" do
          ::Books::BookAuthor.create!(book: ::Books::Book.create!(title: "Another Book"), author: @author, position: 1)

          assert_success reject
          assert ::Books::Author.exists?(@author.id)
        end

        test "an author credited as a translator, named by an import, related to an author, or a merge target is kept" do
          kept = [
            ::Books::Author.create!(name: "Credited Author", provisional: true),
            ::Books::Author.create!(name: "Imported Author", provisional: true),
            ::Books::Author.create!(name: "Related Author", provisional: true),
            ::Books::Author.create!(name: "Merge Target Author", provisional: true)
          ]
          kept.each_with_index { |author, i| ::Books::BookAuthor.create!(book: @book, author: author, position: i + 2) }
          ::Books::Credit.create!(author: kept[0], creditable: ::Books::Book.create!(title: "Translated Book"), role: :translator, position: 1)
          ::Books::GoodreadsImport.create!(user: other_reader, status: :complete).records.create!(record: kept[1], action: :created)
          ::Books::AuthorRelationship.create!(from_author: kept[2], to_author: books_authors(:tolstoy), relation_type: 0)
          RecordRedirect.create!(item_type: "Books::Author", from_id: 999_999_002, to_id: kept[3].id)

          assert_success reject

          assert_equal [true] * 4, kept.map { ::Books::Author.exists?(it.id) }
          assert_not ::Books::Author.exists?(@author.id)
        end

        test "the lease must be live and match, judged before input" do
          assert_failure reject(lease_token: nil), :conflict
          assert_failure reject(lease_token: "x", note: ""), :conflict
          @submission.update_columns(lease_expires_at: 1.second.ago)
          assert_failure reject, :conflict, "expired"
          assert ::Books::Book.exists?(@book.id)
        end

        test "note is required and the API needs sources" do
          assert_failure reject(note: ""), :invalid, "note"
          assert_failure reject(sources: []), :invalid, "sources"
          assert ::Books::Book.exists?(@book.id)
        end

        test "the admin page needs no lease, may omit sources and works on needs_human" do
          row = reviewable_submission(review_status: :needs_human)

          assert_success reject(row, via: "admin_ui", lease_token: nil, sources: [])
          assert_equal ["rejected", "admin_ui"], [fresh(row).review_status, fresh(row).reviewed_via]
        end

        test "a row already closed is a conflict" do
          row = lease(reviewable_submission(review_status: :approved))

          assert_failure reject(row), :conflict
        end

        test "a dry run changes nothing, takes no row lock and keeps the lease" do
          UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @book)
          statements = []
          subscriber = ->(*, payload) { statements << payload[:sql] }

          result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { reject(dry_run: true) }

          assert_success result
          assert result.data[:dry_run]
          assert_equal [@book.id, [@author.id]], [result.data[:book_id], result.data[:author_ids]]
          assert_empty statements.grep(/FOR (NO KEY )?UPDATE/)
          assert_empty statements.grep(/\A\s*(UPDATE|DELETE|INSERT)/)
          row = fresh(@submission)
          assert_equal ["pending", TOKEN], [row.review_status, row.lease_token]
          assert ::Books::Book.exists?(@book.id)
        end

        test "a dry run reports what a real run would refuse" do
          assert_failure reject(dry_run: true, lease_token: "x"), :conflict
          assert_failure reject(dry_run: true, note: ""), :invalid
          assert_failure reject(dry_run: true, sources: []), :invalid
          Review.create!(user: other_reader, reviewable: @book, rating: 3)
          assert_failure reject(dry_run: true), :invalid, "review"
          @book.update_columns(provisional: false)
          assert_failure reject(dry_run: true), :conflict
        end

        test "a failed delete rolls the closing back" do
          ::Books::Book.any_instance.stubs(:destroy!).raises(ActiveRecord::RecordNotDestroyed, "no")

          assert_raises(ActiveRecord::RecordNotDestroyed) { reject }

          assert_equal ["pending", TOKEN], [fresh(@submission).review_status, fresh(@submission).lease_token]
          assert ::Books::Author.exists?(@author.id)
        end

        test "a book that vanished before the lock is a conflict" do
          Reject.any_instance.stubs(:lock_book).returns(nil)

          assert_failure reject, :conflict
        end

        test "Current is set within the call and restored after" do
          Current.acting_user = other_reader
          Current.acting_via = "admin_ui"
          other = reviewable_submission(user: users(:contractor_user), book: @book)

          reject

          assert_equal [@admin.id, "api"], [fresh(other).reviewed_by_id, fresh(other).reviewed_via]
          assert_equal [other_reader, "admin_ui"], [Current.acting_user, Current.acting_via]
        end
      end
    end
  end
end
