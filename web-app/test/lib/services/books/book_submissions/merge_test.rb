require "test_helper"

module Services
  module Books
    module BookSubmissions
      class MergeTest < ActiveSupport::TestCase
        include BookSubmissionReviewHelper

        setup do
          stub_review_side_effects
          @admin = users(:admin_user)
          @reader = users(:regular_user)
          @submission = lease(reviewable_submission(user: @reader))
          @source = @submission.book
          @target = ::Books::Book.create!(title: "The Catalog Copy")
          @sources = ["https://example.com/proof"]
        end

        teardown { Current.reset }

        def merge(submission = @submission, target_id: @target.id, via: "api", lease_token: TOKEN, note: "Same book, other title", sources: @sources, dry_run: false)
          Merge.call(submission: submission, target_id: target_id, user: @admin, via: via, lease_token: lease_token,
            note: note, sources: sources, dry_run: dry_run)
        end

        test "merges into the target and writes the reviewer, note and sources on the moved row" do
          result = merge

          assert_success result
          row = fresh(@submission)
          assert_equal ["merged", @target.id, @admin.id, "api", "Same book, other title", @sources, nil],
            [row.review_status, row.book_id, row.reviewed_by_id, row.reviewed_via, row.review_note, row.review_sources, row.lease_token]
          assert_not ::Books::Book.exists?(@source.id)
          assert_equal [], result.data[:warnings]
          assert_equal @target.id, result.data[:target].id
        end

        test "the reader's list item follows the book to the target" do
          item = UserListItem.create!(user_list: user_lists(:regular_user_books_read), listable: @source)

          merge

          assert_equal [@target.id], UserListItem.where(id: item.id).pluck(:listable_id)
        end

        test "every moved submission gets the note, including another reader's" do
          other = reviewable_submission(user: users(:editor_user), book: @source)
          matched = reviewable_submission(user: users(:contractor_user), book: @source, review_status: :not_needed)

          merge

          [other, matched].each do |row|
            row.reload
            assert_equal ["merged", "Same book, other title", @admin.id], [row.review_status, row.review_note, row.reviewed_by_id]
          end
        end

        test "a row an earlier approval closed keeps its own reviewer and note" do
          done = reviewable_submission(user: users(:editor_user), book: @source, review_status: :approved, review_note: "mine",
            reviewed_by: users(:editor_user), reviewed_via: :admin_ui, reviewed_at: 2.days.ago)

          merge

          done.reload
          assert_equal ["mine", users(:editor_user).id], [done.review_note, done.reviewed_by_id]
        end

        test "AdminMerge never runs inside a transaction of this service" do
          open = ActiveRecord::Base.connection.open_transactions
          seen = nil
          ::Services::Books::AdminMerge.stubs(:call).with { seen = ActiveRecord::Base.connection.open_transactions }.returns(
            ::Services::Books::AdminMerge::Result.new(success?: true, data: {warnings: []}, errors: [])
          )

          merge

          assert_equal open, seen
        end

        test "warnings from the merge are returned" do
          warning = {code: "credits_not_transferred", detail: "1 credit(s) did not transfer"}
          ::Services::Books::AdminMerge.stubs(:call).returns(::Services::Books::AdminMerge::Result.new(success?: true, data: {warnings: [warning]}, errors: []))

          assert_equal [warning], merge.data[:warnings]
        end

        test "the target must exist, not be provisional and not be the source" do
          assert_failure merge(target_id: 0), :invalid, "target"
          assert_failure merge(target_id: "nope"), :invalid, "target"
          assert_failure merge(target_id: nil), :invalid, "target"
          assert_failure merge(target_id: @source.id), :invalid, "itself"
          provisional = ::Books::Book.create!(title: "Provisional Target", provisional: true)
          assert_failure merge(target_id: provisional.id), :invalid, "provisional"
          assert ::Books::Book.exists?(@source.id)
          assert_equal "pending", fresh(@submission).review_status
        end

        test "a source that is no longer provisional is refused" do
          @source.update_columns(provisional: false)

          assert_failure merge, :conflict, "provisional"
        end

        test "refuses a row with no book or one already closed" do
          assert_failure merge(lease(reviewable_submission(book: nil, review_status: :not_needed, status: :failed))), :conflict
          assert_failure merge(lease(reviewable_submission(review_status: :merged))), :conflict
        end

        test "the API needs a live matching lease, and an expired one is a conflict even if nobody else claimed it" do
          assert_failure merge(lease_token: nil), :conflict
          assert_failure merge(lease_token: "other"), :conflict
          @submission.update_columns(lease_expires_at: 1.second.ago)
          assert_failure merge, :conflict, "expired"
          assert ::Books::Book.exists?(@source.id)
        end

        test "state and lease are judged before input and target" do
          assert_failure merge(lease_token: "x", note: "", target_id: 0), :conflict
        end

        test "the admin page needs no lease, may omit sources, and works on needs_human" do
          row = reviewable_submission(review_status: :needs_human)

          assert_success merge(row, via: "admin_ui", lease_token: nil, sources: [])
          assert_equal ["merged", "admin_ui"], [fresh(row).review_status, fresh(row).reviewed_via]
        end

        test "note is required and the API needs sources" do
          assert_failure merge(note: ""), :invalid, "note"
          assert_failure merge(note: "x" * 1_001), :invalid, "note"
          assert_failure merge(sources: []), :invalid, "sources"
          assert_failure merge(sources: ["javascript:alert(1)"]), :invalid, "sources"
          assert ::Books::Book.exists?(@source.id)
        end

        test "a dry run changes nothing and keeps the lease" do
          result = merge(dry_run: true)

          assert_success result
          assert result.data[:dry_run]
          row = fresh(@submission)
          assert_equal ["pending", TOKEN, @source.id], [row.review_status, row.lease_token, row.book_id]
          assert ::Books::Book.exists?(@source.id)
        end

        test "a dry run refuses what a real run would refuse" do
          assert_failure merge(dry_run: true, lease_token: "x"), :conflict
          assert_failure merge(dry_run: true, target_id: @source.id), :invalid
          assert_failure merge(dry_run: true, note: ""), :invalid
          assert_failure merge(dry_run: true, sources: []), :invalid
          provisional = ::Books::Book.create!(title: "Provisional Target Two", provisional: true)
          assert_failure merge(dry_run: true, target_id: provisional.id), :invalid
          @source.update_columns(provisional: false)
          assert_failure merge(dry_run: true), :conflict
        end

        test "a failed merge leaves the row alone and reports why" do
          ::Services::Books::AdminMerge.stubs(:call).returns(::Services::Books::AdminMerge::Result.new(success?: false, data: nil, errors: ["boom"]))

          result = merge

          assert_failure result, :invalid, "boom"
          assert_equal ["pending", TOKEN], [fresh(@submission).review_status, fresh(@submission).lease_token]
        end

        test "a merge that lost the race to another reviewer is a conflict" do
          ::Services::Books::AdminMerge.stubs(:call).with do
            ::Books::BookSubmission.where(id: @submission.id).update_all(review_status: ::Books::BookSubmission.review_statuses[:approved])
            true
          end.returns(::Services::Books::AdminMerge::Result.new(success?: false, data: nil, errors: ["gone"]))

          assert_failure merge, :conflict
        end

        test "Current is set within the call and restored after" do
          Current.acting_user = users(:editor_user)
          Current.acting_via = "admin_ui"

          merge

          assert_equal [@admin.id, "api"], [fresh(@submission).reviewed_by_id, fresh(@submission).reviewed_via]
          assert_equal [users(:editor_user), "admin_ui"], [Current.acting_user, Current.acting_via]
        end

        test "the target id is read as base-10 numerals only" do
          octal_target = ::Books::Book.create!(id: 15, title: "Octal Target")

          ["017", "0xF", "0b1111", "1_5", " 15", "15 ", "-15", "15.0", "1e1"].each do |text|
            assert_failure merge(target_id: text), :invalid, "target"
          end
          assert ::Books::Book.exists?(@source.id)
          assert_success merge(target_id: octal_target.id.to_s)
          assert_equal octal_target.id, fresh(@submission).book_id
        end

        test "a note with NUL or invalid UTF-8 is refused before the merge" do
          assert_failure merge(note: "a \u0000 b"), :invalid, "note"
          assert_failure merge(note: "a \xFF b".b.force_encoding("UTF-8")), :invalid, "note"
          assert_failure merge(sources: ["https://example.com/\u0000"]), :invalid, "sources"
          assert ::Books::Book.exists?(@source.id)
        end

        test "a row settled by someone else while the merge waited for its locks is a conflict and nothing changes" do
          ::Books::Book::Merger.any_instance.stubs(:lock_books).with do
            ::Books::BookSubmission.where(id: @submission.id).update_all(review_status: ::Books::BookSubmission.review_statuses[:approved])
            true
          end

          assert_failure merge, :conflict
          assert ::Books::Book.exists?(@source.id)
          assert_nil fresh(@submission).review_note
        end

        test "a lease lost while the merge waited for its locks is a conflict and nothing changes" do
          ::Books::Book::Merger.any_instance.stubs(:lock_books).with do
            ::Books::BookSubmission.where(id: @submission.id).update_all(lease_token: "taken")
            true
          end

          assert_failure merge, :conflict
          assert ::Books::Book.exists?(@source.id)
          assert_equal "pending", fresh(@submission).review_status
        end

        test "the note lands only on rows this merge closed, never on a row an approver stamped" do
          approved = reviewable_submission(user: users(:editor_user), book: @source, review_status: :approved, review_note: "approver",
            reviewed_by: users(:editor_user), reviewed_via: :admin_ui, reviewed_at: 1.hour.ago)
          other = reviewable_submission(user: users(:contractor_user), book: @source)

          merge

          assert_equal ["approver", users(:editor_user).id], [approved.reload.review_note, approved.reviewed_by_id]
          assert_equal "Same book, other title", other.reload.review_note
        end

        test "a book made public while the merge waited for its locks is a conflict" do
          ::Books::Book::Merger.any_instance.stubs(:lock_books).with do
            ::Books::Book.where(id: @source.id).update_all(provisional: false)
            true
          end

          assert_failure merge, :conflict, "provisional"
          assert ::Books::Book.exists?(@source.id)
          assert_equal "pending", fresh(@submission).review_status
        end

        test "a target that became provisional while the merge waited is a conflict" do
          ::Books::Book::Merger.any_instance.stubs(:lock_books).with do
            ::Books::Book.where(id: @target.id).update_all(provisional: true)
            true
          end

          assert_failure merge, :conflict, "provisional"
          assert ::Books::Book.exists?(@source.id)
        end
      end
    end
  end
end
