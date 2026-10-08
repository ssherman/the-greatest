# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module OlBackfill
      class ApplyBookTest < ActiveSupport::TestCase
        include OlBackfillHelper

        setup do
          @book = books_books(:war_and_peace) # isbn13 9780140447934, Leo Tolstoy, no OL key
          @other = books_books(:crime_and_punishment) # holds OL262758W
          @work = ol_work("OL1W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])
        end

        # The fast pass settles @book on `work`; `works` adds records for the redirect check.
        def fast_client(work = @work, works: {}, errors: [])
          FakeOlClient.new(hits: {["isbn13", "9780140447934"] => [ol_hit(work.key)]}, works: {work.key => work}.merge(works), errors: errors)
        end

        # No identifier hit: /resolve answers.
        def resolve_client(resolution, works: {})
          FakeOlClient.new(resolution: resolution, works: works)
        end

        def work_keys(book = @book) = book.identifiers.where(identifier_type: ApplyBook::WORK_KEY).order(:id).pluck(:value)

        def duplicate_keys(book = @book) = book.identifiers.where(identifier_type: ApplyBook::DUPLICATE_KEY).order(:id).pluck(:value)

        def add_key(value, book: @book, type: ApplyBook::WORK_KEY) = ::Identifier.create!(identifiable: book, identifier_type: type, value: value)

        test "keyed: a book with no key gets one, its author gets one, and the row says how" do
          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1").data

          assert_equal ["OL1W"], work_keys
          assert_equal ["keyed", "identifiers", [], "OL1W", "run-1", 1, "2026-07-31", 3],
            [row.outcome, row.lookup, row.old_keys, row.new_key, row.run_id, row.attempts, row.dump_date, row.matcher_version]
          assert_equal [[books_authors(:tolstoy).id, "OL26783A"]], row.author_changes["added"]
        end

        test "confirmed: the stored key is the answer; any other stored key is removed and logged" do
          add_key("OL1W")
          add_key("OL9W")

          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1").data

          assert_equal [["OL1W"], "confirmed", ["OL1W", "OL9W"]], [work_keys, row.outcome, row.old_keys]
        end

        test "updated: the stored key is one Open Library redirects to the answer (from /resolve)" do
          add_key("OL0W")
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: @work, redirect_sources: ["OL0W"]))

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL1W"], "updated", ["OL0W"], "resolve"], [work_keys, row.outcome, row.old_keys, row.lookup]
        end

        test "updated: the stored key's record is the answer (from the redirect lookup)" do
          add_key("OL0W")

          row = ApplyBook.call(book: @book, client: fast_client(works: {"OL0W" => @work}), run_id: "run-1").data

          assert_equal [["OL1W"], "updated"], [work_keys, row.outcome]
        end

        test "replaced: the stored key is a different work, or dead" do
          add_key("OL5W")
          anna = ol_work("OL5W", title: "Anna Karenina", authors: [["OL26783A", "Leo Tolstoy"]])

          row = ApplyBook.call(book: @book, client: fast_client(works: {"OL5W" => anna}), run_id: "run-1").data
          assert_equal [["OL1W"], "replaced", ["OL5W"]], [work_keys, row.outcome, row.old_keys]

          book = books_books(:got)
          ::Identifier.create!(identifiable: book, identifier_type: ApplyBook::WORK_KEY, value: "OLDEADW")
          got = ol_work("OL7W", title: book.title, authors: [["OL2A", "Stephen King"]])
          dead = ApplyBook.call(book: book, client: resolve_client(ol_resolution(verdict: "accept", work: got)), run_id: "run-1").data
          assert_equal [["OL7W"], "replaced"], [work_keys(book), dead.outcome]
        end

        test "duplicate_pair: another book holds the answer; nothing on this book changes and the pair is flagged" do
          work = ol_work("OL262758W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])

          row = ApplyBook.call(book: @book, client: fast_client(work), run_id: "run-1").data

          assert_empty work_keys
          assert_equal ["duplicate_pair", @other.id, "OL262758W", {}], [row.outcome, row.pair_book_id, row.new_key, row.author_changes]
          pair = ::DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
          assert_equal "ol_backfill", pair.source
          assert_empty books_authors(:tolstoy).identifiers
        end

        test "confirmed: a book that already holds the answer stays confirmed when another book holds it too, and the pair is flagged" do
          work = ol_work("OL262758W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])
          add_key("OL262758W")

          row = ApplyBook.call(book: @book, client: fast_client(work), run_id: "run-1").data

          assert_equal [["OL262758W"], "confirmed", @other.id], [work_keys, row.outcome, row.pair_book_id]
          assert_equal [[books_authors(:tolstoy).id, "OL26783A"]], row.author_changes["added"]
          pair = ::DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
          assert_equal "ol_backfill", pair.source
        end

        test "unsure: no trusted answer leaves the stored key alone" do
          add_key("OL5W")

          row = ApplyBook.call(book: @book, client: resolve_client(ol_resolution(verdict: "abstain")), run_id: "run-1").data

          assert_equal [["OL5W"], "unsure", ["OL5W"], nil], [work_keys, row.outcome, row.old_keys, row.new_key]
        end

        test "a book with no authors is unsure and keeps its stored key" do
          work = ol_work("OL262758W", title: "Crime and Punishment", authors: [["OL1A", "Fyodor Dostoevsky"]])

          row = ApplyBook.call(book: @other, client: resolve_client(ol_resolution(verdict: "accept", work: work)), run_id: "run-1").data

          assert_equal [["OL262758W"], "unsure"], [work_keys(@other), row.outcome]
        end

        test "duplicates from /resolve are saved as the duplicate type; one another book holds is a pair instead" do
          add_key("OL3W", book: @other)
          client = resolve_client(ol_resolution(verdict: "accept", work: @work, duplicates: ["OL2W", "OL3W"]))

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL2W"], ["OL2W"]], [duplicate_keys, row.duplicate_keys]
          assert ::DuplicateCandidate.exists?(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
          assert_equal "keyed", row.outcome
        end

        test "an answer the book held as a duplicate key becomes its work key, and the duplicate copy goes" do
          add_key("OL1W", type: ApplyBook::DUPLICATE_KEY)

          ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")

          assert_equal [["OL1W"], []], [work_keys, duplicate_keys]
        end

        test "the same work answered for a second book in the run is a duplicate_pair" do
          ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")
          got = books_books(:got)
          same = ol_work("OL1W", title: got.title, authors: [["OL2A", "Stephen King"]])

          row = ApplyBook.call(book: got, client: resolve_client(ol_resolution(verdict: "accept", work: same)), run_id: "run-1").data

          assert_equal ["duplicate_pair", @book.id], [row.outcome, row.pair_book_id]
          assert_empty work_keys(got)
        end

        test "an Open Library error after keys changed persists nothing" do
          add_key("OL5W")
          # identifier, works_batch (fast pass), then the redirect check's works_batch raises
          client = fast_client(errors: [nil, nil, ::Books::OpenLibrary::Exceptions::ServerError.new("down", 500)])

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { ApplyBook.call(book: @book, client: client, run_id: "run-1") }

          assert_equal ["OL5W"], work_keys
          assert_not ::Books::OpenLibraryBackfill.exists?(book: @book)
        end

        test "record_failure writes a failed row, then counts attempts; a later success clears the error" do
          ApplyBook.record_failure(book: @book, run_id: "run-1", error: "down")
          row = ApplyBook.record_failure(book: @book, run_id: "run-2", error: "still down")
          assert_equal ["failed", 2, "still down", "run-2"], [row.outcome, row.attempts, row.error, row.run_id]

          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-3").data
          assert_equal ["keyed", 3, nil], [row.outcome, row.attempts, row.error]
        end

        test "losing the insert race to another run is an unsuccessful result, not an error" do
          ::Books::OpenLibraryBackfill.create!(book: @book, outcome: :unsure, run_id: "other-run")
          ::Books::OpenLibraryBackfill.stubs(:find_or_initialize_by).returns(::Books::OpenLibraryBackfill.new(book: @book))

          result = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")

          assert_not result.success?
          assert_empty work_keys
        end
      end
    end
  end
end
