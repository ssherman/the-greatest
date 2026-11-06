# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      module Apply
        class LeftoversTest < ActiveSupport::TestCase
          include GoodreadsReimportApplyHelper

          setup do
            setup_reader
            @other = books_books(:crime_and_punishment)
            UserListItem.where(listable: @other).delete_all
          end

          def apply(verdict)
            result = Row.call(verdict: verdict)
            settled = result.data[:outcome] == :applied || (result.data[:outcome] == :noop && result.data[:final])
            verdict.update!(applied_at: Time.current) if settled && verdict.reload.applied_at.nil?
            result
          end

          # Legacy put both entries on the book, the realistic shape: the to-read row finds its item already there.
          def split_rows_with_both_items
            [UserListItem.create!(user_list: list(:read), listable: @from), UserListItem.create!(user_list: list(:want_to_read), listable: @from),
              row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @from),
              row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @to)]
          end

          test "legacy holds both entries and the in-place row applies last: the Read leftover is still cleaned" do
            read, want, a, b = split_rows_with_both_items

            apply(b)
            assert UserListItem.exists?(read.id), "A is not settled yet"
            result = apply(a)

            assert_equal [:noop, true], result.data.values_at(:outcome, :final)
            assert_not UserListItem.exists?(read.id)
            assert UserListItem.exists?(want.id)
          end

          test "an add row heading to the book explains its shelf's item even when it wrote nothing" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            c = row_verdict(csv_row(exclusive_shelf: "read"), action: "add", from: nil, to: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @from)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @to)

            [c, a, b].each { |verdict| apply(verdict) }

            assert UserListItem.exists?(read.id)
          end

          test "a keep row heading to the book explains its shelf's item" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            reading = UserListItem.create!(user_list: list(:reading), listable: @from)
            keep = row_verdict(csv_row(exclusive_shelf: "read"), action: "keep", from: @from, to: @from)
            keep.update!(applied_at: Time.current)
            copy = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)

            apply(copy)

            assert UserListItem.exists?(read.id)
            assert_not UserListItem.exists?(reading.id)
          end

          test "a rejected sibling row means nothing is swept" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @other)
            b.update!(status: :rejected)

            apply(a)

            assert UserListItem.exists?(read.id)
          end

          test "a proposed sibling row means nothing is swept" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @other)
            b.update!(status: :proposed)

            apply(a)

            assert UserListItem.exists?(read.id)
          end

          test "a CSV row of the book with no verdict yet means nothing is swept" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            csv_row(exclusive_shelf: "read", legacy_book_id: @from.id)

            apply(a)

            assert UserListItem.exists?(read.id)
          end

          test "a book merged into this one is followed: a keep row naming the merged-in book explains the item" do
            gone_id = ::Books::Book.maximum(:id) + 1000
            ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "books:#{@from.id}:#{gone_id}", decided_by: :rule, status: :approved,
              payload: {"source_id" => gone_id, "target_id" => @from.id})
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            reading = UserListItem.create!(user_list: list(:reading), listable: @from)
            keep = row_verdict(csv_row(exclusive_shelf: "read"), action: "keep", from: @from, to: @from)
            keep.update!(applied_at: Time.current, payload: keep.payload.merge("to_book_id" => gone_id, "from_book_id" => gone_id))
            copy = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)

            apply(copy)

            assert UserListItem.exists?(read.id)
            assert_not UserListItem.exists?(reading.id)
          end

          # A keep row naming `gone_id`, applied, with a Read item and a Reading item on the book; then a copy away.
          def keep_row_naming(gone_id)
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            reading = UserListItem.create!(user_list: list(:reading), listable: @from)
            keep = row_verdict(csv_row(exclusive_shelf: "read"), action: "keep", from: @from, to: @from)
            keep.update!(applied_at: Time.current, payload: keep.payload.merge("to_book_id" => gone_id, "from_book_id" => gone_id))
            apply(row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to))
            [read, reading]
          end

          def gone_ids(count) = Array.new(count) { |i| ::Books::Book.maximum(:id) + 1000 + i }

          test "an admin merge recorded only as a redirect is followed: a keep row naming the merged-in book explains the item" do
            gone_id, = gone_ids(1)
            RecordRedirect.create!(item_type: "Books::Book", from_id: gone_id, to_id: @from.id)

            read, reading = keep_row_naming(gone_id)

            assert UserListItem.exists?(read.id)
            assert_not UserListItem.exists?(reading.id)
          end

          test "a merge_books verdict then a redirect are followed as one chain" do
            first, second = gone_ids(2)
            ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "books:#{second}:#{first}", decided_by: :rule, status: :approved,
              payload: {"source_id" => first, "target_id" => second})
            RecordRedirect.create!(item_type: "Books::Book", from_id: second, to_id: @from.id)

            read, reading = keep_row_naming(first)

            assert UserListItem.exists?(read.id)
            assert_not UserListItem.exists?(reading.id)
          end

          test "a redirect then a merge_books verdict are followed as one chain" do
            first, second = gone_ids(2)
            RecordRedirect.create!(item_type: "Books::Book", from_id: first, to_id: second)
            ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "books:#{@from.id}:#{second}", decided_by: :rule, status: :approved,
              payload: {"source_id" => second, "target_id" => @from.id})

            read, reading = keep_row_naming(first)

            assert UserListItem.exists?(read.id)
            assert_not UserListItem.exists?(reading.id)
          end

          test "book_ids follows redirects back to their sources and ignores a deleted book's redirect" do
            merged, deleted = gone_ids(2)
            RecordRedirect.create!(item_type: "Books::Book", from_id: merged, to_id: @from.id)
            RecordRedirect.create!(item_type: "Books::Book", from_id: deleted, to_id: nil)
            RecordRedirect.create!(item_type: "Books::Author", from_id: merged + 5, to_id: @from.id)

            ids = Leftovers.book_ids(@from)

            assert_includes ids, merged
            assert_not_includes ids, deleted
            assert_not_includes ids, merged + 5
          end

          test "a row naming a deleted book (a redirect with no target) follows nowhere, so the sweep waits" do
            gone_id, = gone_ids(1)
            RecordRedirect.create!(item_type: "Books::Book", from_id: gone_id, to_id: nil)

            read, reading = keep_row_naming(gone_id)

            assert UserListItem.exists?(read.id)
            assert UserListItem.exists?(reading.id)
          end

          test "a redirect alone, like the one a mixed delete writes, does not change where MergedBook sends a row" do
            gone_id, = gone_ids(1)
            RecordRedirect.create!(item_type: "Books::Book", from_id: gone_id, to_id: @from.id)

            assert_nil GoodreadsReplay::Apply::MergedBook.call(gone_id)
          end

          test "R6 through the real merger: a new book merged into this one with no pair or verdict keeps the keep row's item" do
            new_book = ::Books::Book.create!(title: "Re-import Created", book_kind: :standalone)
            read = UserListItem.create!(user_list: list(:read), listable: new_book)
            keep = row_verdict(csv_row(exclusive_shelf: "read"), action: "keep", from: new_book, to: new_book)
            keep.update!(applied_at: Time.current)
            copy = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            ::Books::Book::Merger.call(source: new_book, target: @from)
            assert_not RecordRedirect.exists?(from_id: new_book.id), "a post-migration id records no redirect"

            apply(copy)

            assert UserListItem.exists?(read.id)
            assert_equal @from.id, read.reload.listable_id
          end

          test "a row naming a gone book nothing follows makes the sweep wait, and a resolvable one does not" do
            gone_id, = gone_ids(1)
            reading = UserListItem.create!(user_list: list(:reading), listable: @from)
            stray = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @other, to: @other)
            stray.update!(applied_at: Time.current, payload: stray.payload.merge("from_book_id" => gone_id, "to_book_id" => gone_id))
            copy = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)

            apply(copy)
            assert UserListItem.exists?(reading.id)

            RecordRedirect.create!(item_type: "Books::Book", from_id: gone_id, to_id: @other.id)
            Leftovers.sweep(copy.reload, @from, @user)
            assert_not UserListItem.exists?(reading.id)
          end

          test "a rejected row naming a gone book does not hold the sweep" do
            gone_id, = gone_ids(1)
            reading = UserListItem.create!(user_list: list(:reading), listable: @from)
            stray = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @other, to: @other)
            stray.update!(status: :rejected, payload: stray.payload.merge("from_book_id" => gone_id, "to_book_id" => gone_id))
            copy = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)

            apply(copy)

            assert_not UserListItem.exists?(reading.id)
          end

          test "R8: copies from a mixed book later redirected here are not a copy from this book, so a move in sweeps nothing" do
            mixed_id, = gone_ids(1)
            [@to, books_books(:crime_and_punishment)].each_with_index do |dest, i|
              row = row_verdict(csv_row(exclusive_shelf: (i.zero? ? "read" : "currently-reading")), action: "copy", from: @from, to: dest)
              row.update!(applied_at: Time.current, payload: row.payload.merge("from_book_id" => mixed_id))
            end
            RecordRedirect.create!(item_type: "Books::Book", from_id: mixed_id, to_id: @from.id)
            hand_added = UserListItem.create!(user_list: list(:reading), listable: @from)
            source = ::Books::Book.create!(title: "Move Source", book_kind: :standalone)
            UserListItem.create!(user_list: list(:want_to_read), listable: source)
            move = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "move", from: source, to: @from)

            apply(move)

            assert UserListItem.exists?(hand_added.id)
          end

          def public_goal
            ::Books::ReadingGoal.create!(user: @user, name: "2020", target_count: 10, public: true,
              starts_on: Date.new(2020, 1, 1), ends_on: Date.new(2020, 12, 31))
          end

          test "a swept dated Read entry purges the reader's reading-goal pages after commit" do
            public_goal
            read = UserListItem.create!(user_list: list(:read), listable: @from, completed_on: Date.new(2020, 5, 5))
            copy = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            urls = Entries.goal_urls(@user, [read])
            assert urls.any?
            ::Books::ReadingGoals::PurgeCachedPagesJob.expects(:perform_async).with("books", urls).once

            apply(copy)

            assert_not UserListItem.exists?(read.id)
          end

          # A row whose from-book and destination both have leftovers: copy A -> B, while an applied copy B -> C makes
          # B's sweep run too.
          def row_sweeping_two_books
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            reading = UserListItem.create!(user_list: list(:reading), listable: @to)
            row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @to, to: @other).update!(applied_at: Time.current)
            [read, reading, row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)]
          end

          test "a row sweeping two books sweeps both" do
            read, reading, copy = row_sweeping_two_books

            apply(copy)

            assert_not UserListItem.exists?(read.id)
            assert_not UserListItem.exists?(reading.id)
          end

          test "when the second of a row's two sweeps raises, the verdict stays unapplied and the retry sweeps both" do
            read, reading, copy = row_sweeping_two_books
            Leftovers.stubs(:settled?).returns(true).then.raises(RuntimeError, "boom")

            assert_raises(RuntimeError) { Row.call(verdict: copy) }

            assert_nil copy.reload.applied_at
            assert UserListItem.exists?(read.id)
            assert UserListItem.exists?(reading.id)

            Leftovers.unstub(:settled?)
            apply(copy)

            assert_not UserListItem.exists?(read.id)
            assert_not UserListItem.exists?(reading.id)
          end

          def count_queries
            count = 0
            counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) || payload[:cached] }
            ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
            count
          end

          test "a sweep costs the same number of queries however many unrelated rows the reader has" do
            _read, _want, a, b = split_rows_with_both_items
            apply(a)
            apply(b)
            few = count_queries { Leftovers.sweep(b, @from, @user) }

            20.times do
              row = csv_row(exclusive_shelf: "read", legacy_book_id: @other.id)
              keep = row_verdict(row, action: "keep", from: @other, to: @other)
              keep.update!(applied_at: Time.current)
            end
            many = count_queries { Leftovers.sweep(b, @from, @user) }

            assert_equal few, many
          end

          test "a crash between the copy and the sweep leaves the verdict unapplied, and the retry cleans" do
            read, _want, a, b = split_rows_with_both_items
            apply(a)
            UserListItem.any_instance.stubs(:destroy!).raises("boom")

            assert_raises(RuntimeError) { Row.call(verdict: b) }

            UserListItem.any_instance.unstub(:destroy!)
            assert_nil b.reload.applied_at
            assert UserListItem.exists?(read.id)
            apply(b)
            assert_not UserListItem.exists?(read.id)
          end

          def lists_on(book, user = @user)
            UserListItem.joins(:user_list).where(listable: book, user_lists: {user_id: user.id}).map { |item| item.user_list.list_type }.sort
          end

          def split_rows
            legacy_read = UserListItem.create!(user_list: list(:read), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @from)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @to)
            [legacy_read, a, b]
          end

          test "rows A (to-read, stays) and B (read, goes) on a non-mixed book: the legacy Read item goes once both applied, and is recorded" do
            legacy_read, a, b = split_rows

            apply(b)
            assert UserListItem.exists?(legacy_read.id), "A is not applied yet, so the book is not settled"
            apply(a)

            assert_equal ["want_to_read"], lists_on(@from)
            assert_equal ["read"], lists_on(@to)
            trail = a.reload.payload["leftovers_removed"]
            assert_equal [legacy_read.id], trail.map { |item| item["id"] }
            assert_equal @user.id, trail.first["user_id"]
          end

          test "rows that all go elsewhere leave the reader no entry on the book" do
            read = UserListItem.create!(user_list: list(:read), listable: @from)
            reading = UserListItem.create!(user_list: list(:reading), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @other)

            apply(a)
            assert UserListItem.exists?(read.id)
            apply(b)

            assert_empty lists_on(@from)
            assert_equal [read.id, reading.id].sort, b.reload.payload["leftovers_removed"].map { |item| item["id"] }.sort
          end

          test "a favorites item stays while a row of the reader heads to the book and goes when none does" do
            fav = UserListItem.create!(user_list: list(:favorites), listable: @from)
            _legacy, a, b = split_rows
            apply(a)
            apply(b)
            assert UserListItem.exists?(fav.id)
          end

          test "a favorites item goes when no row of the reader heads to the book" do
            fav = UserListItem.create!(user_list: list(:favorites), listable: @from)
            UserListItem.create!(user_list: list(:read), listable: @from)
            a = row_verdict(csv_row(exclusive_shelf: "to-read"), action: "copy", from: @from, to: @to)
            b = row_verdict(csv_row(exclusive_shelf: "read"), action: "copy", from: @from, to: @other)

            apply(a)
            apply(b)

            assert_not UserListItem.exists?(fav.id)
            assert UserListItem.exists?(user_list: list(:favorites), listable: @to), "copy_other_lists already copied it"
          end

          test "another reader's items and the review are untouched, and so is a reader with no applied copy" do
            _legacy, a, b = split_rows
            review = Review.create!(user: @user, reviewable: @from, rating: 4, body: "mine")
            bystander = User.create!(email: "by-#{SecureRandom.hex(3)}@example.com", role: :user, email_verified: false)
            theirs = UserListItem.create!(user_list: ::Books::UserList.find_by!(user: bystander, list_type: :read), listable: @from)

            apply(a)
            apply(b)

            assert UserListItem.exists?(theirs.id)
            assert_equal @from, review.reload.reviewable
          end

          test "sweeping again removes nothing" do
            _legacy, a, b = split_rows
            apply(a)
            apply(b)

            assert_equal 0, Leftovers.sweep(b, @from, @user)
            assert_equal ["want_to_read"], lists_on(@from)
          end

          test "a retry of the last copy after a crash still ends clean" do
            _legacy, a, b = split_rows
            apply(a)
            Row.call(verdict: b)

            Row.call(verdict: b.reload)

            assert_equal ["want_to_read"], lists_on(@from)
            assert_equal ["read"], lists_on(@to)
          end

          test "a mixed book is left to Apply::Mixed" do
            ::Books::RepairVerdict.create!(kind: :reimport_mixed, subject_key: "reimport:book:#{@from.id}", decided_by: :rule, status: :approved,
              payload: {"book_id" => @from.id, "redirect_to_book_id" => @to.id, "row_keys" => []})
            legacy_read, a, b = split_rows
            apply(a)
            apply(b)

            assert UserListItem.exists?(legacy_read.id)
          end
        end
      end
    end
  end
end
