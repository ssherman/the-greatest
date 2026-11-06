# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module Verification
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

        def work_keys_with_source = @book.identifiers.where(identifier_type: ApplyBook::WORK_KEY).pluck(:value, :source)

        def work_keys(book = @book) = book.identifiers.where(identifier_type: ApplyBook::WORK_KEY).order(:id).pluck(:value)

        def duplicate_keys(book = @book) = book.identifiers.where(identifier_type: ApplyBook::DUPLICATE_KEY).order(:id).pluck(:value)

        # @other becomes a book that really looks like @work: same title.
        def make_other_a_real_holder = @other.update_columns(title: "War and Peace")

        def add_key(value, book: @book, type: ApplyBook::WORK_KEY, source: nil) = ::Identifier.create!(identifiable: book, identifier_type: type, value: value, source: source)

        test "keyed: a book with no key gets one, its author gets one, and the row says how" do
          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1").data

          assert_equal ["OL1W"], work_keys
          assert_equal ["keyed", "identifiers", [], "OL1W", "run-1", 1, "2026-07-31", 3],
            [row.work_outcome, row.lookup, row.old_keys, row.new_key, row.run_id, row.attempts, row.dump_date, row.matcher_version]
          assert_equal [[books_authors(:tolstoy).id, "OL26783A"]], row.author_changes["added"]
        end

        test "confirmed: the stored key is the answer; any other stored key is removed and logged" do
          add_key("OL1W")
          add_key("OL9W")

          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1").data

          assert_equal [["OL1W"], "confirmed", ["OL1W", "OL9W"]], [work_keys, row.work_outcome, row.old_keys]
        end

        test "updated: the stored key is one Open Library redirects to the answer (from /resolve)" do
          add_key("OL0W")
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: @work, redirect_sources: ["OL0W"]))

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL1W"], "updated", ["OL0W"], "resolve"], [work_keys, row.work_outcome, row.old_keys, row.lookup]
        end

        test "updated: the stored key's record is the answer (from the redirect lookup)" do
          add_key("OL0W")

          row = ApplyBook.call(book: @book, client: fast_client(works: {"OL0W" => @work}), run_id: "run-1").data

          assert_equal [["OL1W"], "updated"], [work_keys, row.work_outcome]
        end

        test "replaced: the stored key is a different work, or dead" do
          add_key("OL5W")
          anna = ol_work("OL5W", title: "Anna Karenina", authors: [["OL26783A", "Leo Tolstoy"]])

          row = ApplyBook.call(book: @book, client: fast_client(works: {"OL5W" => anna}), run_id: "run-1").data
          assert_equal [["OL1W"], "replaced", ["OL5W"]], [work_keys, row.work_outcome, row.old_keys]

          book = books_books(:got)
          ::Identifier.create!(identifiable: book, identifier_type: ApplyBook::WORK_KEY, value: "OLDEADW")
          got = ol_work("OL7W", title: book.title, authors: [["OL2A", "Stephen King"]])
          dead = ApplyBook.call(book: book, client: resolve_client(ol_resolution(verdict: "accept", work: got)), run_id: "run-1").data
          assert_equal [["OL7W"], "replaced"], [work_keys(book), dead.work_outcome]
        end

        test "duplicate_pair: another book holds the answer; nothing on this book changes and the pair is flagged" do
          make_other_a_real_holder
          work = ol_work("OL262758W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])

          row = ApplyBook.call(book: @book, client: fast_client(work), run_id: "run-1").data

          assert_empty work_keys
          assert_equal ["duplicate_pair", @other.id, "OL262758W", {}], [row.work_outcome, row.pair_book_id, row.new_key, row.author_changes]
          pair = ::DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
          assert_equal "ol_backfill", pair.source
          assert_empty books_authors(:tolstoy).identifiers
        end

        test "confirmed: a book that already holds the answer stays confirmed when another book holds it too, and the pair is flagged" do
          make_other_a_real_holder
          work = ol_work("OL262758W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])
          add_key("OL262758W")

          row = ApplyBook.call(book: @book, client: fast_client(work), run_id: "run-1").data

          assert_equal [["OL262758W"], "confirmed", @other.id], [work_keys, row.work_outcome, row.pair_book_id]
          assert_equal [[books_authors(:tolstoy).id, "OL26783A"]], row.author_changes["added"]
          pair = ::DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
          assert_equal "ol_backfill", pair.source
        end

        test "unsure: no trusted answer leaves the stored key alone" do
          add_key("OL5W")

          row = ApplyBook.call(book: @book, client: resolve_client(ol_resolution(verdict: "abstain")), run_id: "run-1").data

          assert_equal [["OL5W"], "unsure", ["OL5W"], nil], [work_keys, row.work_outcome, row.old_keys, row.new_key]
        end

        test "a book with no authors is unsure and keeps its stored key" do
          work = ol_work("OL262758W", title: "Crime and Punishment", authors: [["OL1A", "Fyodor Dostoevsky"]])

          row = ApplyBook.call(book: @other, client: resolve_client(ol_resolution(verdict: "accept", work: work)), run_id: "run-1").data

          assert_equal [["OL262758W"], "unsure"], [work_keys(@other), row.work_outcome]
        end

        test "duplicates from /resolve are saved as the duplicate type; one another book holds is a pair instead" do
          make_other_a_real_holder
          add_key("OL3W", book: @other)
          client = resolve_client(ol_resolution(verdict: "accept", work: @work, duplicates: ["OL2W", "OL3W"]))

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL2W"], ["OL2W"]], [duplicate_keys, row.duplicate_keys]
          assert ::DuplicateCandidate.exists?(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
          assert_equal "keyed", row.work_outcome
        end

        test "an answer the book held as a duplicate key becomes its work key, and the duplicate copy goes" do
          add_key("OL1W", type: ApplyBook::DUPLICATE_KEY)

          ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")

          assert_equal [["OL1W"], []], [work_keys, duplicate_keys]
        end

        test "the same work answered for a second book in the run is a duplicate_pair" do
          ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")
          got = books_books(:got)
          got.update_columns(alternate_titles: ["War and Peace"])
          same = ol_work("OL1W", title: "War and Peace", authors: [["OL2A", "Stephen King"]])

          row = ApplyBook.call(book: got, client: resolve_client(ol_resolution(verdict: "accept", work: same)), run_id: "run-1").data

          assert_equal ["duplicate_pair", @book.id], [row.work_outcome, row.pair_book_id]
          assert_empty work_keys(got)
        end

        test "an Open Library error after keys changed persists nothing" do
          add_key("OL5W")
          # identifier, works_batch (fast pass), then the redirect check's works_batch raises
          client = fast_client(errors: [nil, nil, ::Books::OpenLibrary::Exceptions::ServerError.new("down", 500)])

          assert_raises(::Books::OpenLibrary::Exceptions::ServerError) { ApplyBook.call(book: @book, client: client, run_id: "run-1") }

          assert_equal ["OL5W"], work_keys
          assert_not ::Books::Verification.exists?(book: @book)
        end

        test "record_failure writes a failed row, then counts attempts; a later success clears the error" do
          ApplyBook.record_failure(book: @book, run_id: "run-1", error: "down")
          row = ApplyBook.record_failure(book: @book, run_id: "run-2", error: "still down")
          assert_equal ["failed", 2, "still down", "run-2"], [row.work_outcome, row.attempts, row.error, row.run_id]

          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-3").data
          assert_equal ["keyed", 3, nil], [row.work_outcome, row.attempts, row.error]
        end

        test "a settled row is skipped without calling Open Library" do
          %i[confirmed updated replaced keyed duplicate_pair reverted].each do |outcome|
            ::Books::Verification.where(book: @book).delete_all
            row = ::Books::Verification.create!(book: @book, work_outcome: outcome, run_id: "old", old_keys: ["OL5W"], new_key: "OL1W")
            client = fast_client

            result = ApplyBook.call(book: @book, client: client, run_id: "run-2")

            assert_not result.success?, outcome
            assert_empty client.calls, outcome
            assert_equal [outcome.to_s, "old", ["OL5W"]], [row.reload.work_outcome, row.run_id, row.old_keys]
          end
        end

        test "an unsure or failed row is processed again" do
          %i[unsure failed].each do |outcome|
            ::Books::Verification.where(book: @book).delete_all
            ::Books::Verification.create!(book: @book, work_outcome: outcome, run_id: "old")
            ::Identifier.where(identifiable: @book, identifier_type: ApplyBook::WORK_KEY).destroy_all

            assert ApplyBook.call(book: @book, client: fast_client, run_id: "run-2").success?, outcome
          end
        end

        test "a row another run settled during the lookup is not overwritten" do
          client = fast_client
          book_id = @book.id
          client.define_singleton_method(:works_batch) do |keys|
            ::Books::Verification.create!(book_id: book_id, work_outcome: :replaced, run_id: "other", old_keys: ["OL5W"], new_key: "OL1W")
            super(keys)
          end

          result = ApplyBook.call(book: @book, client: client, run_id: "run-1")

          assert_not result.success?
          assert_empty work_keys
          row = ::Books::Verification.find_by!(book: @book)
          assert_equal ["replaced", "other", ["OL5W"]], [row.work_outcome, row.run_id, row.old_keys]
        end

        test "record_failure leaves a settled row alone" do
          settled = ::Books::Verification.create!(book: @book, work_outcome: :replaced, run_id: "old", old_keys: ["OL5W"], new_key: "OL1W")

          row = ApplyBook.record_failure(book: @book, run_id: "run-2", error: "down")

          assert_equal settled.id, row.id
          assert_equal ["replaced", "old", 1, nil], [settled.reload.work_outcome, settled.run_id, settled.attempts, settled.error]
        end

        test "confirm_only: confirmed, no key or author change, flag set" do
          add_key("OL1W")
          add_key("OL9W")
          resolution = ol_resolution(verdict: "abstain", work: @work, duplicates: ["OL2W"])

          row = ApplyBook.call(book: @book, client: resolve_client(resolution), run_id: "run-1").data

          assert_equal [["OL1W", "OL9W"], [], "confirmed", ["OL1W", "OL9W"], "OL1W", true, {}],
            [work_keys, duplicate_keys, row.work_outcome, row.old_keys, row.new_key, row.confirmed_on_abstain, row.author_changes]
          assert_empty books_authors(:tolstoy).identifiers
        end

        def key_source(value, book: @book, type: ApplyBook::WORK_KEY)
          book.identifiers.find_by!(identifier_type: type, value: value).source
        end

        test "provenance: a keyed book's new key is open_library" do
          ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")

          assert_equal "open_library", key_source("OL1W")
        end

        test "provenance: a confirmed book's legacy key becomes open_library" do
          add_key("OL1W", source: :legacy)

          ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")

          assert_equal "open_library", key_source("OL1W")
        end

        test "provenance: a confirm_only book's key becomes open_library and nothing else changes" do
          add_key("OL1W", source: :legacy)
          add_key("OL9W", source: :legacy)
          resolution = ol_resolution(verdict: "abstain", work: @work, duplicates: ["OL2W"])

          ApplyBook.call(book: @book, client: resolve_client(resolution), run_id: "run-1")

          assert_equal [["OL1W", "OL9W"], [], "open_library", "legacy"], [work_keys, duplicate_keys, key_source("OL1W"), key_source("OL9W")]
        end

        test "provenance: saved duplicate keys and added author keys are open_library" do
          ApplyBook.call(book: @book, client: resolve_client(ol_resolution(verdict: "accept", work: @work, duplicates: ["OL2W"])), run_id: "run-1")

          assert_equal "open_library", key_source("OL2W", type: ApplyBook::DUPLICATE_KEY)
          assert_equal "open_library", key_source("OL26783A", book: books_authors(:tolstoy), type: AuthorKeys::AUTHOR_KEY)
        end

        test "provenance: an unsure book's key keeps its source" do
          add_key("OL5W", source: :legacy)

          ApplyBook.call(book: @book, client: resolve_client(ol_resolution(verdict: "abstain")), run_id: "run-1")

          assert_equal "legacy", key_source("OL5W")
        end

        test "an ordinary confirmed row does not carry the abstain flag" do
          add_key("OL1W")

          assert_equal false, ApplyBook.call(book: @book, client: fast_client, run_id: "run-1").data.confirmed_on_abstain
        end

        test "a work key given while another book holds it as a duplicate key flags the pair, and the key stays" do
          make_other_a_real_holder
          add_key("OL1W", book: @other, type: ApplyBook::DUPLICATE_KEY)

          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1").data

          assert_equal [["OL1W"], "keyed", nil], [work_keys, row.work_outcome, row.pair_book_id]
          pair = ::DuplicateCandidate.find_by(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
          assert_equal "ol_backfill", pair.source
        end

        test "replaced: an old key whose record agrees is kept as a duplicate key" do
          add_key("OL5W")
          old = ol_work("OL5W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])

          row = ApplyBook.call(book: @book, client: fast_client(works: {"OL5W" => old}), run_id: "run-1").data

          assert_equal [["OL1W"], ["OL5W"], "replaced", ["OL5W"], ["OL5W"]], [work_keys, duplicate_keys, row.work_outcome, row.old_keys, row.duplicate_keys]
        end

        test "replaced: an old key whose record disagrees is dropped, as is one that is dead" do
          add_key("OL5W")
          add_key("OL6W")
          anna = ol_work("OL5W", title: "Anna Karenina", authors: [["OL26783A", "Leo Tolstoy"]])

          row = ApplyBook.call(book: @book, client: fast_client(works: {"OL5W" => anna}), run_id: "run-1").data

          assert_equal [["OL1W"], [], "replaced", []], [work_keys, duplicate_keys, row.work_outcome, row.duplicate_keys]
        end

        test "replaced: an agreeing old key that another book holds as its work key is flagged, not saved" do
          make_other_a_real_holder
          add_key("OL262758W")
          old = ol_work("OL262758W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])

          row = ApplyBook.call(book: @book, client: fast_client(works: {"OL262758W" => old}), run_id: "run-1").data

          assert_equal [["OL1W"], [], "replaced"], [work_keys, duplicate_keys, row.work_outcome]
          assert ::DuplicateCandidate.exists?(item_type: "Books::Book", item_a_id: [@book.id, @other.id].min, item_b_id: [@book.id, @other.id].max)
        end

        test "replaced: the old record's authors are fetched only when the names differ" do
          add_key("OL5W")
          old = ol_work("OL5W", title: "War and Peace", authors: [["OL5A", "Лев Толстой"]])
          client = fast_client(works: {"OL5W" => old})
          client.instance_variable_get(:@authors)["OL5A"] = ol_author("OL5A", name: "Лев Толстой", alternate_names: ["Leo Tolstoy"])

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL5W"], 1], [row.duplicate_keys, client.calls.count { |call| call.first == :authors_batch }]
        end

        # --- removed: a stored key whose record is clearly a different book ---

        def abstain_client(works: {}, authors: {}) = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain"), works: works, authors: authors)

        test "removed: an unsure book whose stored key's record disagrees on title and author loses the key" do
          add_key("OL5W")
          other = ol_work("OL5W", title: "Anna Karenina", authors: [["OL9A", "Someone Else"]])

          row = ApplyBook.call(book: @book, client: abstain_client(works: {"OL5W" => other}), run_id: "run-1").data

          assert_equal [[], "removed", ["OL5W"], nil, [], nil],
            [work_keys, row.work_outcome, row.old_keys, row.new_key, row.duplicate_keys, row.pair_book_id]
        end

        test "unsure: a stored key whose record agrees on the title only, or the author only, is kept" do
          add_key("OL5W")
          title_only = ol_work("OL5W", title: "War and Peace", authors: [["OL9A", "Someone Else"]])
          row = ApplyBook.call(book: @book, client: abstain_client(works: {"OL5W" => title_only}), run_id: "run-1").data
          assert_equal [["OL5W"], "unsure"], [work_keys, row.work_outcome]

          ::Books::Verification.where(book: @book).delete_all
          author_only = ol_work("OL5W", title: "Anna Karenina", authors: [["OL26783A", "Leo Tolstoy"]])
          row = ApplyBook.call(book: @book, client: abstain_client(works: {"OL5W" => author_only}), run_id: "run-2").data
          assert_equal [["OL5W"], "unsure"], [work_keys, row.work_outcome]
        end

        test "unsure: a dead stored key is not clearly a different book, and a record whose author is found by alternate name is kept" do
          add_key("OL5W")
          row = ApplyBook.call(book: @book, client: abstain_client, run_id: "run-1").data
          assert_equal [["OL5W"], "unsure"], [work_keys, row.work_outcome]

          ::Books::Verification.where(book: @book).delete_all
          russian = ol_work("OL5W", title: "Anna Karenina", authors: [["OL5A", "Лев Толстой"]])
          client = abstain_client(works: {"OL5W" => russian}, authors: {"OL5A" => ol_author("OL5A", name: "Лев Толстой", alternate_names: ["Leo Tolstoy"])})
          row = ApplyBook.call(book: @book, client: client, run_id: "run-2").data
          assert_equal [["OL5W"], "unsure"], [work_keys, row.work_outcome]
        end

        test "unsure: a book with no authors keeps a stored key whose record has a different title" do
          add_key("OL5W")
          other = ol_work("OL5W", title: "Anna Karenina", authors: [["OL9A", "Someone Else"]])
          @book.book_authors.destroy_all

          row = ApplyBook.call(book: @book.reload, client: abstain_client(works: {"OL5W" => other}), run_id: "run-1").data

          assert_equal [["OL5W"], "unsure"], [work_keys, row.work_outcome]
        end

        test "unsure: a record with no authors and a different title keeps the stored key, and no authors are fetched" do
          add_key("OL5W")
          client = abstain_client(works: {"OL5W" => ol_work("OL5W", title: "Anna Karenina")})

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL5W"], "unsure"], [work_keys, row.work_outcome]
          assert_empty client.calls.select { |call| call.first == :authors_batch }
        end

        test "unsure: author records that come back empty are unknown too" do
          add_key("OL5W")
          client = abstain_client(works: {"OL5W" => ol_work("OL5W", title: "Anna Karenina", authors: [["OL9A", ""]])})

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL5W"], "unsure"], [work_keys, row.work_outcome]
        end

        test "unsure: the key Open Library accepted is never removed, even when its record disagrees" do
          add_key("OL5W")
          wrong = ol_work("OL5W", title: "Anna Karenina", authors: [["OL9A", "Someone Else"]])
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "accept", work: wrong), works: {"OL5W" => wrong})

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL5W"], "unsure"], [work_keys, row.work_outcome]
        end

        test "unsure: the top candidate Open Library abstained on is never removed either" do
          add_key("OL5W")
          wrong = ol_work("OL5W", title: "Anna Karenina", authors: [["OL9A", "Someone Else"]])
          client = FakeOlClient.new(resolution: ol_resolution(verdict: "abstain", work: wrong), works: {"OL5W" => wrong})

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL5W"], "unsure"], [work_keys, row.work_outcome]
        end

        test "an unsure book settles on the passing one of two stored keys and the clearly different one goes, with one works_batch call" do
          add_key("OL5W")
          add_key("OL6W")
          wrong = ol_work("OL5W", title: "Anna Karenina", authors: [["OL9A", "Someone Else"]])
          right = ol_work("OL6W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])
          client = abstain_client(works: {"OL5W" => wrong, "OL6W" => right})

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL6W"], "confirmed", ["OL5W", "OL6W"]], [work_keys, row.work_outcome, row.old_keys]
          assert_equal [[:works_batch, ["OL5W", "OL6W"]]], client.calls.select { |call| call.first == :works_batch }
        end

        test "removed with a survivor: neither stored key passes, only the clearly different one goes" do
          add_key("OL5W")
          add_key("OL6W")
          wrong = ol_work("OL5W", title: "Anna Karenina", authors: [["OL9A", "Someone Else"]])
          unknown_author = ol_work("OL6W", title: "War and Peace") # title agrees, no author to confirm: not verified, not clearly different
          client = abstain_client(works: {"OL5W" => wrong, "OL6W" => unknown_author})

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL6W"], "removed", ["OL5W", "OL6W"]], [work_keys, row.work_outcome, row.old_keys]
          assert_equal [[:works_batch, ["OL5W", "OL6W"]], [:works_batch, ["OL5W", "OL6W"]]], client.calls.select { |call| call.first == :works_batch }
        end

        test "an unsure book with no stored key makes no works_batch call" do
          client = abstain_client

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal "unsure", row.work_outcome
          assert_empty client.calls.select { |call| call.first == :works_batch }
        end

        test "a removed row is settled: it is skipped and never overwritten" do
          ::Books::Verification.create!(book: @book, work_outcome: :removed, run_id: "old", old_keys: ["OL5W"], stage: :done)
          client = fast_client

          assert_not ApplyBook.call(book: @book, client: client, run_id: "run-2").success?
          assert_empty client.calls
        end

        # --- second-chance answers ---

        def stub_answer(lookup, work: @work)
          Lookup.stubs(:call).returns(Lookup::Answer.new(work: work, lookup: lookup, duplicates: [], redirect_sources: [],
            source_version: {dump_date: "2026-07-31", matcher_version: 3}))
        end

        test "a resolve_candidate answer settles the book and writes no author key" do
          stub_answer(:resolve_candidate)

          row = ApplyBook.call(book: @book, client: FakeOlClient.new, run_id: "run-1").data

          assert_equal [["OL1W"], "keyed", "resolve_candidate", {}], [work_keys, row.work_outcome, row.lookup, row.author_changes]
        end

        test "a resolve accept still writes the author key" do
          stub_answer(:resolve)

          row = ApplyBook.call(book: @book, client: FakeOlClient.new, run_id: "run-1").data

          assert_equal [[books_authors(:tolstoy).id, "OL26783A"]], row.author_changes["added"]
        end

        test "a held key that is also a candidate is confirmed through held_key and keeps its other passing exact-title held key as a duplicate" do
          add_key("OL5W")
          add_key("OL7W")
          add_key("OL8W")
          tolstoy = [["OL26783A", "Leo Tolstoy"]]
          resolution = ol_resolution_with(verdict: "abstain", candidates: [
            {work: ol_work("OL4W", title: "Anna Karenina", authors: tolstoy)}, {work: ol_work("OL5W", title: "War and Peace", authors: tolstoy)}
          ])
          client = resolve_client(resolution, works: {
            "OL7W" => ol_work("OL7W", title: "War and Peace", authors: tolstoy),
            "OL8W" => ol_work("OL8W", title: "War and Peace: A Novel", authors: tolstoy)
          })

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal ["confirmed", "held_key", ["OL5W"], ["OL7W"], ["OL7W"]],
            [row.work_outcome, row.lookup, work_keys, duplicate_keys, row.duplicate_keys]
        end

        test "a held_key answer for a held key is confirmed and the key becomes open_library" do
          add_key("OL1W")
          stub_answer(:held_key)

          row = ApplyBook.call(book: @book, client: FakeOlClient.new, run_id: "run-1").data

          assert_equal ["confirmed", "open_library", {}], [row.work_outcome, @book.identifiers.find_by!(value: "OL1W").source, row.author_changes]
        end

        test "a removed row reset to the work stage is reprocessed and keeps its old keys" do
          ::Books::Verification.create!(book: @book, work_outcome: :removed, run_id: "old", old_keys: ["OL3W"], stage: :work)
          add_key("OL1W")
          stub_answer(:held_key)

          result = ApplyBook.call(book: @book, client: FakeOlClient.new, run_id: "run-2")

          assert result.success?
          assert_equal ["OL3W", "OL1W"], result.data.old_keys
          assert_equal 2, result.data.attempts
        end

        test "a removed row reset to work that finds nothing stays removed and can still be reverted" do
          row = ::Books::Verification.create!(book: @book, work_outcome: :removed, run_id: "old", old_keys: ["OL3W"], stage: :work)
          Lookup.stubs(:call).returns(Lookup::Answer.new(work: nil, lookup: :exact_title, duplicates: [], redirect_sources: [], source_version: nil))

          ApplyBook.call(book: @book, client: FakeOlClient.new, run_id: "run-2")

          assert_equal ["removed", ["OL3W"], "exact_title", "run-2"], row.reload.then { |r| [r.work_outcome, r.old_keys, r.lookup, r.run_id] }
          assert Revert.call(book: @book).success?
          assert_equal [["OL3W", "legacy"]], work_keys_with_source
        end

        test "record_failure keeps a removed row removed" do
          row = ::Books::Verification.create!(book: @book, work_outcome: :removed, run_id: "old", old_keys: ["OL3W"], stage: :work)

          ApplyBook.record_failure(book: @book, run_id: "run-2", error: StandardError.new("boom"))

          assert_equal ["removed", "boom", 2], row.reload.then { |r| [r.work_outcome, r.error, r.attempts] }
        end

        test "a removed row with no held key is keyed by a worldcat_isbns answer, keeps its old keys, writes no author key" do
          ::Books::Verification.create!(book: @book, work_outcome: :removed, run_id: "old", old_keys: ["OL3W"], stage: :work)
          stub_answer(:worldcat_isbns)

          row = ApplyBook.call(book: @book, client: FakeOlClient.new, run_id: "run-2").data

          assert_equal ["keyed", ["OL3W"], {}], [row.work_outcome, row.old_keys, row.author_changes]
        end

        # --- pairs only for a holder that really looks like the same work ---

        test "a holder whose title disagrees with the answer is no pair: the book is keyed and nothing is flagged" do
          work = ol_work("OL262758W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])

          row = ApplyBook.call(book: @book, client: fast_client(work), run_id: "run-1").data

          assert_equal [["OL262758W"], "keyed", nil], [work_keys, row.work_outcome, row.pair_book_id]
          assert_not ::DuplicateCandidate.exists?(item_type: "Books::Book", source: "ol_backfill")
        end

        test "confirmed with a holder whose title disagrees: no pair book and no flag" do
          work = ol_work("OL262758W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])
          add_key("OL262758W")

          row = ApplyBook.call(book: @book, client: fast_client(work), run_id: "run-1").data

          assert_equal ["confirmed", nil], [row.work_outcome, row.pair_book_id]
          assert_not ::DuplicateCandidate.exists?(item_type: "Books::Book", source: "ol_backfill")
        end

        test "with several holders the lowest-id real one is the pair; a non-real lower id is ignored" do
          make_other_a_real_holder
          wrong = books_books(:got)
          assert_operator wrong.id, :<, @other.id, "premise: the non-real holder has the lower id"
          ::Identifier.create!(identifiable: wrong, identifier_type: ApplyBook::WORK_KEY, value: "OL262758W")
          work = ol_work("OL262758W", title: "War and Peace", authors: [["OL26783A", "Leo Tolstoy"]])

          row = ApplyBook.call(book: @book, client: fast_client(work), run_id: "run-1").data

          assert_equal ["duplicate_pair", @other.id], [row.work_outcome, row.pair_book_id]
          assert_equal 1, ::DuplicateCandidate.where(item_type: "Books::Book", source: "ol_backfill").count
        end

        test "a duplicate key another book holds with a disagreeing title is saved and flags nothing" do
          add_key("OL3W", book: @other)
          client = resolve_client(ol_resolution(verdict: "accept", work: @work, duplicates: ["OL3W"]))

          row = ApplyBook.call(book: @book, client: client, run_id: "run-1").data

          assert_equal [["OL3W"], ["OL3W"]], [duplicate_keys, row.duplicate_keys]
          assert_not ::DuplicateCandidate.exists?(item_type: "Books::Book", source: "ol_backfill")
        end

        test "a duplicate-key holder with a disagreeing title is not flagged when the work key is given" do
          add_key("OL1W", book: @other, type: ApplyBook::DUPLICATE_KEY)

          ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")

          assert_not ::DuplicateCandidate.exists?(item_type: "Books::Book", source: "ol_backfill")
        end

        test "losing the insert race to another run is an unsuccessful result, not an error" do
          ::Books::Verification.create!(book: @book, work_outcome: :unsure, run_id: "other-run")
          ::Books::Verification.stubs(:find_or_initialize_by).returns(::Books::Verification.new(book: @book))

          result = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1")

          assert_not result.success?
          assert_empty work_keys
        end

        test "a uniqueness failure that is not the backfill row propagates" do
          AuthorKeys.stubs(:call).raises(ActiveRecord::RecordNotUnique, "duplicate author key")

          assert_raises(ActiveRecord::RecordNotUnique) { ApplyBook.call(book: @book, client: fast_client, run_id: "run-1") }
          assert_nil ::Books::Verification.find_by(book: @book)
        end

        test "a uniqueness failure while retrying a failed row propagates and leaves the row" do
          failed = ::Books::Verification.create!(book: @book, work_outcome: :failed, run_id: "old-run", error: "boom", attempts: 1)
          AuthorKeys.stubs(:call).raises(ActiveRecord::RecordNotUnique, "duplicate author key")

          assert_raises(ActiveRecord::RecordNotUnique) { ApplyBook.call(book: @book, client: fast_client, run_id: "run-1") }
          failed.reload
          assert_equal ["failed", "old-run", 1], [failed.work_outcome, failed.run_id, failed.attempts]
        end

        test "the row carries the cohort and moves to identifiers when a work settled" do
          row = ApplyBook.call(book: @book, client: fast_client, run_id: "run-1", cohort: :post_import).data

          assert row.cohort_post_import?
          assert row.stage_identifiers?
        end

        test "an unsure book moves straight to worldcat" do
          row = ApplyBook.call(book: @book, client: resolve_client(ol_resolution(verdict: "abstain")), run_id: "run-1").data

          assert row.stage_worldcat?
          assert row.cohort_pre_import?
        end

        test "a failed lookup leaves the row at work" do
          row = ApplyBook.record_failure(book: @book, run_id: "run-1", error: "boom")

          assert row.stage_work?
        end
      end
    end
  end
end
