# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      class ReportTest < ActiveSupport::TestCase
        setup do
          @user = users(:regular_user)
          @book = books_books(:war_and_peace)
          @other = books_books(:crime_and_punishment)
          @edition = books_goodreads_editions(:war_and_peace_edition)
          @import = ::Books::GoodreadsImport.create!(user: @user, source: :legacy_replay, status: :complete, legacy_import_id: 91)
          @row = ::Books::GoodreadsImportRow.create!(import: @import, row_number: 1, goodreads_edition: @edition, raw: {"Title" => "War and Peace"})
          @snapshot = Pathname.new(Dir.mktmpdir).join("counts.json")
          Report.stubs(:snapshot_path).returns(@snapshot)
        end

        def verdict(kind, key, payload, **attrs)
          ::Books::RepairVerdict.create!({kind: kind, subject_key: key, payload: payload, decided_by: :rule, status: :approved}.merge(attrs))
        end

        def row_verdict(row, to_book, **attrs)
          verdict(:reimport_row, "reimport:row:#{row.import_id}:#{row.row_number}",
            {"import_id" => row.import_id, "row_number" => row.row_number, "to_book_id" => to_book.id, "from_book_id" => nil, "action" => "add",
             "goodreads_edition_id" => row.goodreads_edition_id}, **attrs)
        end

        test "reports counts, the AI agreement rate and the stuck lists" do
          verdict(:reimport_match, "reimport:edition:#{@edition.id}", {"book_id" => @book.id, "facts" => {"full_title" => "War and Peace"}})
          verdict(:reimport_match, "reimport:edition:9", {"facts" => {"full_title" => "Rejected Title"}}, status: :rejected)
          verdict(:reimport_match, "reimport:edition:10", {}, status: :proposed)
          row_verdict(@row, @book, applied_at: Time.current)
          verdict(:reimport_row, "reimport:row:#{@import.id}:2", {"to_book_id" => @book.id, "action" => "keep"}, error: "RuntimeError: boom")
          verdict(:reimport_row, "reimport:row:#{@import.id}:3", {"closed_reason" => "no entry"}, applied_at: Time.current)
          verdict(:reimport_mixed, "reimport:book:#{@other.id}", {"book_id" => @other.id, "row_keys" => [[@import.id, 1], [@import.id, 77]]})
          verdict(:reimport_guess, "reimport:guess:Review:1", {"to_book_id" => @book.id})

          report = Report.call

          assert_includes report, "reimport_match approved 1"
          assert_includes report, "reimport_match rejected 1"
          assert_includes report, "reimport_match proposed 1"
          assert_includes report, "add approved 1"
          assert_includes report, "AI agreement: 1 of 3 matches auto-approved (33.3%)"
          assert_includes report, "guesses: 1"
          assert_includes report, "mixed books stuck waiting (rows with no current, non-rejected row verdict): 1"
          assert_includes report, "book ##{@other.id}: 1 rows, e.g. reimport:row:#{@import.id}:77"
          assert_includes report, "rejected matches (their rows wait for Shane): 1"
          assert_includes report, "reimport:edition:9: Rejected Title"
          assert_includes report, "closed as final no-ops: 1"
          assert_includes report, "no entry: 1"
          assert_includes report, "verdicts with an error: 1"
          assert_includes report, "RuntimeError: boom"
          assert_includes report, "rows with no current book (added from the CSV alone): 1"
        end

        test "acceptance: a destination whose title differs from the CSV is listed unless a high-confidence match explains it" do
          row_verdict(@row, @other, applied_at: Time.current)
          unmatched = verdict(:reimport_match, "reimport:edition:#{@edition.id}", {"book_id" => @other.id, "ai" => {"answer" => nil}})

          assert_includes Report.call, "no approved verdict explaining it: 1"

          unmatched.update!(payload: {"book_id" => @other.id, "ai" => {"answer" => @other.id, "confidence" => "high"}})

          assert_includes Report.call, "no approved verdict explaining it: 0"
        end

        test "acceptance: a destination with the CSV title is fine" do
          row_verdict(@row, @book, applied_at: Time.current)

          assert_includes Report.call, "no approved verdict explaining it: 0"
        end

        test "acceptance: reports no snapshot, then the users whose counts dropped" do
          assert_includes Report.call, "dropped: no snapshot"

          list = ::Books::UserList.create!(user: @user, name: "Shelf", list_type: :custom)
          item = UserListItem.create!(user_list: list, listable: @book)
          assert_equal 1, Report.snapshot
          assert_includes Report.call, "beyond the destroys recorded: 0"

          item.destroy!
          report = Report.call

          assert_includes report, "beyond the destroys recorded: 1"
          assert_match(/user #{@user.id} items: \d+ -> \d+ \(0 recorded destroys\)/, report)
        end

        test "a lost review is not hidden by a gained item, and a recorded collision destroy is an explained drop" do
          Review.where(user: @user).delete_all
          review = Review.create!(user: @user, reviewable: @book, rating: 4, title: "T", body: "B")
          Report.snapshot
          review.destroy!
          list = ::Books::UserList.create!(user: @user, name: "Shelf", list_type: :custom)
          UserListItem.create!(user_list: list, listable: @other)

          report = Report.call
          assert_includes report, "beyond the destroys recorded: 1"
          assert_includes report, "user #{@user.id} reviews: 1 -> 0 (0 recorded destroys)"

          row_verdict(@row, @book, applied_at: Time.current).update!(
            payload: {"user_id" => @user.id, "moved" => {"destroyed_reviews" => [{"id" => review.id}], "destroyed_items" => []}}
          )
          report = Report.call
          assert_includes report, "beyond the destroys recorded: 0"
          assert_includes report, "explained drops (destroyed by a collision the verdicts recorded; not a loss): 1"
          assert_includes report, "user #{@user.id} reviews: 1 -> 0 (1 recorded destroys)"
        end

        test "snapshot refuses to overwrite without redo" do
          assert_equal 1, Report.snapshot
          first = @snapshot.read

          assert_nil Report.snapshot
          assert_equal first, @snapshot.read
          assert_equal 1, Report.snapshot(replace: true)
        end

        test "acceptance: mixed books still present are counted" do
          MixedBooks.stubs(:ids).returns(Set[@other.id])

          assert_includes Report.call, "mixed books still present: 1"
        end

        test "snapshot writes per-user item and review counts for users with in-scope rows" do
          items = UserListItem.where(listable_type: "Books::Book", user_list: ::UserList.where(user: @user)).count
          reviews = Review.where(reviewable_type: "Books::Book", user: @user).count
          list = ::Books::UserList.create!(user: @user, name: "Shelf", list_type: :custom)
          UserListItem.create!(user_list: list, listable: books_books(:of_mice_and_men))
          Review.create!(user: @user, reviewable: books_books(:of_mice_and_men), rating: 4, title: "T", body: "B")

          assert_equal 1, Report.snapshot

          users = JSON.parse(@snapshot.read)["users"]
          assert_equal({@user.id.to_s => {"items" => items + 1, "reviews" => reviews + 1}}, users)
        end

        def task_class(answers)
          Class.new do
            define_method(:initialize) { |facts:, books:| @facts = facts }
            define_method(:call) { answers.fetch(@facts.full_title) }
          end
        end

        test "sample lists every row the independent reviewer answers no to" do
          bad_edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: 5_551, signature: "sig-bad", title: "Wrong One", primary_author: "X")
          bad_row = ::Books::GoodreadsImportRow.create!(import: @import, row_number: 2, goodreads_edition: bad_edition, raw: {"Title" => "Wrong One"})
          row_verdict(@row, @book, applied_at: Time.current)
          row_verdict(bad_row, @other, applied_at: Time.current)
          yes = Struct.new(:success?, :data).new(true, {book_id: @book.id})
          no = Struct.new(:success?, :data).new(true, {book_id: nil})

          report = Report.sample(n: 10, mixed_books: 0, task_class: task_class("War and Peace" => yes, "Wrong One" => no))

          assert_includes report, "checked 2 rows"
          assert_includes report, "answered no: 1"
          assert_includes report, "reimport:row:#{@import.id}:2:"
          assert_includes report, "book ##{@other.id}"
          assert_not_includes report, "reimport:row:#{@import.id}:1:"
        end

        test "sample also checks every row of former mixed books and reports rows it could not check" do
          row_verdict(@row, @book, applied_at: Time.current)
          verdict(:reimport_mixed, "reimport:book:#{@other.id}", {"book_id" => @other.id, "row_keys" => [[@import.id, 1]]}, applied_at: Time.current)
          failure = Struct.new(:success?, :data).new(false, {})

          report = Report.sample(n: 0, mixed_books: 20, task_class: task_class("War and Peace" => failure))

          assert_includes report, "checked 1 rows"
          assert_includes report, "could not be checked: 1"
        end
      end
    end
  end
end
