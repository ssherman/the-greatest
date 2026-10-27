require "test_helper"

module Workflows
  module Books
    module Steps
      class GoodreadsTest < ActiveSupport::TestCase
        Decision = ::Books::Goodreads::GateTurn::Decision
        FETCH = Decision.new(action: :fetch, wait: nil, refusal: nil)
        StoredStep = Struct.new(:result) do
          def update_columns(result:) = (self.result = result)
        end
        STRAY = 147719920
        MAIN = 168668

        setup do
          @book = ::Books::Book.create!(title: "Catch-22: A Novel")
          @book.authors << ::Books::Author.create!(name: "Joseph Heller")
          @run = Struct.new(:options).new({})
          @gate = stub(blocked_until: Time.utc(2026, 10, 26, 6))
          ::Books::Goodreads::FetchGate.stubs(:new).returns(@gate)
          ::Books::Goodreads::GateTurn.stubs(:after_fetch)
          @stored = {}
          @dues = []
          @fetches = []
        end

        # Plays the engine: runs the adapter on the stored result and merges
        # what a wait hands back, as Coordinator.finish_wait does.
        def execute
          step = StoredStep.new(@stored)
          outcome = begin
            Goodreads.new.call(step: step, run: @run, target: @book)
          ensure
            @stored = step.result # what update_columns wrote, kept even when the call raises
          end
          @stored = @stored.merge(outcome.result || {})
          outcome
        end

        def gate_decisions(*decisions)
          ::Books::Goodreads::GateTurn.stubs(:call).with { |gate:, due:| @dues << due }.returns(*decisions)
        end

        def waiting(seconds = 15) = Decision.new(action: :wait, wait: seconds, refusal: nil)

        def refused(reason) = Decision.new(action: :refused, wait: nil, refusal: reason)

        def row(id = STRAY, title: "(Catch-22) By Joseph Heller (Author) Paperback", authors: ["Joseph Heller"])
          {goodreads_book_id: id, title: title, author_names: authors, year: 1961, ratings_count: 900_000, editions_count: 521}
        end

        def search_row(*rows, query: "catch-22", fetched_at: Time.current)
          ::Books::GoodreadsSearch.create!(query: query, outcome: :found, fetched_at: fetched_at, rows: rows)
        end

        def page(id, best: nil, version: 2, html: true, title: "Catch-22", outcome: :found, authors: [{"name" => "Joseph Heller", "role" => "Author", "primary" => true}])
          record = ::Books::GoodreadsPage.create!(goodreads_book_id: id, outcome: outcome, fetched_at: Time.current, source: :fetched,
            parser_version: version, best_book_id: best, title: title, authors: authors)
          record.html.attach(io: StringIO.new(Zlib.gzip("<html></html>")), filename: "p.html.gz", content_type: "application/gzip", identify: false) if html
          record
        end

        def stub_search_fetch(*makers, outcome: :found)
          ::Services::Books::GoodreadsPages::FetchSearch.stubs(:call).with { |query:, **| @fetches << [:search, query] }
            .returns(*makers.map { |m| lazy_result(outcome, m, :search) })
        end

        def stub_page_fetch(*results)
          ::Services::Books::GoodreadsPages::FetchPage.stubs(:call).with { |goodreads_book_id:, **| @fetches << [:page, goodreads_book_id] }
            .returns(*results.map { |outcome, maker| lazy_result(outcome, maker, :page) })
        end

        # The record is built when the step reads it, after the service "ran":
        # building it up front would put it in the cache already.
        def lazy_result(outcome, maker, key)
          Object.new.tap do |result|
            result.define_singleton_method(:data) { @data ||= {:outcome => outcome, key => maker&.call} }
          end
        end

        def pick(id) = ::Services::Books::GoodreadsEnrichment::PickCandidate.stubs(:call).returns(::Books::Goodreads::SearchPage::Row.new(**row(id)))

        def ledger_rows = @book.enrichments.where(kind: "books.goodreads")

        test "no data: search, stray page, main page, apply, one fetch per execution and one turn per fetch" do
          gate_decisions(waiting, FETCH, waiting, FETCH, waiting, FETCH)
          stub_search_fetch(-> { search_row(row) })
          pick(STRAY)
          stub_page_fetch([:found, -> { page(STRAY, best: MAIN) }], [:found, -> { page(MAIN, best: MAIN) }])
          applied = nil
          ::Services::Books::GoodreadsEnrichment::Apply.expects(:call).with { |book:, page:| applied = page }.returns(stub)

          first = execute
          assert_equal [:wait, true, "search", []], [first.kind, first.result.dig("progress", "due"), @stored.dig("progress", "phase"), @fetches]

          execute # search fetch, pick, then the page turn is not due
          assert_equal [[:search, "Catch-22"]], @fetches
          assert_equal ["page", STRAY, true], @stored["progress"].values_at("phase", "goodreads_book_id", "due")

          execute # stray page fetch, follow best, main page's turn not due
          assert_equal [[:search, "Catch-22"], [:page, STRAY]], @fetches
          assert_equal [MAIN, true], @stored["progress"].values_at("goodreads_book_id", "followed_best")

          done = execute
          assert_equal [[:search, "Catch-22"], [:page, STRAY], [:page, MAIN]], @fetches
          assert_equal [:succeeded, "matched", true, MAIN], [done.kind, done.outcome, done.result["matched"], done.result["goodreads_book_id"]]
          assert_equal ::Books::GoodreadsPage.find_by(goodreads_book_id: MAIN).id, done.result["page_id"]
          assert_equal MAIN, applied.goodreads_book_id
          assert_equal [false, true, false, true, false, true], @dues
        end

        test "a raise after a spent due turn is stored as spent, so the retry reserves again" do
          @stored = {"progress" => {"phase" => "page", "goodreads_book_id" => MAIN, "origin" => "search", "due" => true,
                                    "followed_best" => false, "searched_retry" => false}, "other" => 1}
          gate_decisions(FETCH, waiting)
          ::Services::Books::GoodreadsPages::FetchPage.stubs(:call).raises("fetch blew up")

          assert_raises(RuntimeError) { execute }
          assert_equal [false, 1], [@stored.dig("progress", "due"), @stored["other"]]

          execute

          assert_equal [true, false], @dues
        end

        test "after a wait the next execution takes its due turn instead of reserving again" do
          gate_decisions(waiting, FETCH)
          stub_search_fetch(-> { search_row(row) })
          pick(STRAY)
          stub_page_fetch([:found, -> { page(MAIN, best: MAIN) }])
          ::Services::Books::GoodreadsEnrichment::Apply.stubs(:call).returns(stub)

          execute
          execute

          assert_equal [false, true], @dues.first(2)
        end

        test "a fresh cached search and a cached v2 page match with no fetch in one execution" do
          search_row(row(MAIN, title: "Catch-22"))
          page(MAIN, best: MAIN)
          pick(MAIN)
          ::Books::Goodreads::GateTurn.expects(:call).never
          ::Services::Books::GoodreadsPages::FetchSearch.expects(:call).never
          ::Services::Books::GoodreadsPages::FetchPage.expects(:call).never
          ::Services::Books::GoodreadsEnrichment::Apply.expects(:call).once.returns(stub)

          outcome = execute

          assert_equal [:succeeded, "matched"], [outcome.kind, outcome.outcome]
        end

        test "a stale cached search is fetched again" do
          search_row(row, fetched_at: 31.days.ago)
          gate_decisions(FETCH)
          stub_search_fetch(-> { search_row(row(MAIN, title: "Elsewhere", authors: ["Someone Else"]), query: "catch-22 heller") })
          ::Services::Books::GoodreadsEnrichment::PickCandidate.expects(:call).never

          execute

          assert_equal [[:search, "Catch-22"]], @fetches
        end

        test "a version 1 page with HTML is re-read, not fetched" do
          old = page(MAIN, best: MAIN, version: 1)
          search_row(row(MAIN, title: "Catch-22"))
          pick(MAIN)
          ::Services::Books::GoodreadsPages::Reparse.expects(:call).with(page: old).returns(old.tap { it.parser_version = 2 })
          ::Services::Books::GoodreadsPages::FetchPage.expects(:call).never
          ::Services::Books::GoodreadsEnrichment::Apply.stubs(:call).returns(stub)

          assert_equal "matched", execute.outcome
        end

        test "a found page without HTML is refetched with refresh" do
          page(MAIN, best: MAIN, html: false)
          search_row(row(MAIN, title: "Catch-22"))
          pick(MAIN)
          gate_decisions(FETCH)
          ::Services::Books::GoodreadsPages::FetchPage.expects(:call).with(goodreads_book_id: MAIN, refresh: true)
            .returns(stub(data: {outcome: :found, page: ::Books::GoodreadsPage.find_by(goodreads_book_id: MAIN)}))
          ::Services::Books::GoodreadsEnrichment::Apply.stubs(:call).returns(stub)

          assert_equal "matched", execute.outcome
        end

        test "a known id goes straight to the page, and a failed check falls back to search once" do
          @book.identifiers.create!(identifier_type: :books_work_goodreads_id, value: STRAY.to_s)
          page(STRAY, best: STRAY, title: "Something Else Entirely")
          search_row(row(MAIN, title: "Catch-22"))
          page(MAIN, best: MAIN)
          pick(MAIN)
          ::Services::Books::GoodreadsEnrichment::Apply.expects(:call).with { |book:, page:| page.goodreads_book_id == MAIN }.returns(stub)

          outcome = execute

          assert_equal [:succeeded, "matched", MAIN], [outcome.kind, outcome.outcome, outcome.result["goodreads_book_id"]]
          assert_empty ledger_rows
        end

        test "a known id that fails and whose search page fails too is rejected, not looped" do
          @book.identifiers.create!(identifier_type: :books_work_goodreads_id, value: STRAY.to_s)
          page(STRAY, best: STRAY, title: "Something Else Entirely")
          search_row(row(MAIN, title: "Catch-22"))
          page(MAIN, best: MAIN, title: "Catch-22 Study Guide")
          pick(MAIN)
          ::Services::Books::GoodreadsEnrichment::Apply.expects(:call).never

          outcome = execute

          assert_equal [:succeeded, "rejected", false], [outcome.kind, outcome.outcome, outcome.result["matched"]]
          assert_equal [["unrecognized", "rejected"]], ledger_rows.pluck(:outcome, :reason)
        end

        test "the daily cap waits until the next UTC midnight and keeps the phase" do
          travel_to Time.utc(2026, 10, 25, 22) do
            gate_decisions(refused(:daily_cap))

            outcome = execute

            assert_equal [Time.utc(2026, 10, 26), false, "search"], [outcome.run_after, outcome.result.dig("progress", "due"), outcome.result.dig("progress", "phase")]
          end
        end

        test "a blocked gate waits until blocked_until" do
          gate_decisions(refused(:blocked))

          outcome = execute

          assert_equal [Time.utc(2026, 10, 26, 6), false], [outcome.run_after, outcome.result.dig("progress", "due")]
        end

        test "an unparseable page blocks the gate through after_fetch and waits until blocked_until" do
          search_row(row(MAIN, title: "Catch-22"))
          pick(MAIN)
          gate_decisions(FETCH)
          stub_page_fetch([:unparseable, nil])
          ::Books::Goodreads::GateTurn.expects(:after_fetch).with(gate: @gate, outcome: :unparseable)

          outcome = execute

          assert_equal [:wait, Time.utc(2026, 10, 26, 6), "page", MAIN], [outcome.kind, outcome.run_after, @stored.dig("progress", "phase"), @stored.dig("progress", "goodreads_book_id")]
          assert_equal 1, @stored.dig("progress", "bad_fetches")
        end

        test "a second unparseable fetch of the same page ends the step as a miss with one ledger row" do
          search_row(row(MAIN, title: "Catch-22"))
          pick(MAIN)
          gate_decisions(FETCH)
          stub_page_fetch([:unparseable, nil], [:unparseable, nil])

          first = execute
          second = execute

          assert_equal :wait, first.kind
          assert_equal [:succeeded, "unparseable", false], [second.kind, second.outcome, second.result["matched"]]
          assert_equal [["unrecognized", "unparseable"]], ledger_rows.pluck(:outcome, :reason)
        end

        test "a fetcher that is down raises so the coordinator retries" do
          gate_decisions(FETCH)
          stub_search_fetch(nil, outcome: :fetcher_down)

          assert_raises(StandardError) { execute }
        end

        test "an unavailable Goodreads raises" do
          search_row(row(MAIN, title: "Catch-22"))
          pick(MAIN)
          gate_decisions(FETCH)
          stub_page_fetch([:unavailable, nil])

          assert_raises(StandardError) { execute }
        end

        test "a best page that names the first page again is not followed a second time" do
          stray = page(STRAY, best: MAIN)
          search_row(row(STRAY))
          pick(STRAY)
          main = page(MAIN, best: STRAY)
          applied = nil
          ::Services::Books::GoodreadsEnrichment::Apply.expects(:call).with { |book:, page:| applied = page }.returns(stub)

          outcome = execute

          assert_equal [MAIN, main.id], [applied.goodreads_book_id, outcome.result["page_id"]]
          assert_not_equal stray.id, outcome.result["page_id"]
        end

        test "a best id that is not_found applies the page already held" do
          stray = page(STRAY, best: MAIN)
          search_row(row(STRAY))
          pick(STRAY)
          page(MAIN, outcome: :not_found, html: false, title: nil, authors: [])
          applied = nil
          ::Services::Books::GoodreadsEnrichment::Apply.expects(:call).with { |book:, page:| applied = page }.returns(stub)

          outcome = execute

          assert_equal [STRAY, stray.id], [applied.goodreads_book_id, outcome.result["page_id"]]
        end

        test "no survivors after the surname retry is no_match with one ledger row" do
          gate_decisions(FETCH, waiting, FETCH)
          other = row(1, title: "Closing Time", authors: ["Someone Else"])
          stub_search_fetch(-> { search_row(other) }, -> { search_row(other, query: "catch-22 heller") })
          ::Services::Books::GoodreadsEnrichment::PickCandidate.expects(:call).never

          first = execute
          assert_equal [:wait, 1, "search"], [first.kind, @fetches.size, @stored.dig("progress", "phase")]
          final = execute

          assert_equal [[:search, "Catch-22"], [:search, "Catch-22 Heller"]], @fetches.map { [it[0], it[1]] }
          assert_equal [:succeeded, "no_match", false], [final.kind, final.outcome, final.result["matched"]]
          assert_equal [["unrecognized", "no_match"]], ledger_rows.pluck(:outcome, :reason)
        end

        test "no pick is no_match" do
          search_row(row)
          ::Services::Books::GoodreadsEnrichment::PickCandidate.stubs(:call).returns(nil)

          outcome = execute

          assert_equal [:succeeded, "no_match", false], [outcome.kind, outcome.outcome, outcome.result["matched"]]
          assert_equal 1, ledger_rows.count
        end

        test "a raise from Apply propagates" do
          search_row(row(MAIN, title: "Catch-22"))
          page(MAIN, best: MAIN)
          pick(MAIN)
          ::Services::Books::GoodreadsEnrichment::Apply.stubs(:call).raises(ActiveRecord::RecordInvalid)

          assert_raises(ActiveRecord::RecordInvalid) { execute }
        end

        test "a book with no authors searches on the run's first author name for the retry" do
          bare = ::Books::Book.create!(title: "Catch-22")
          @run = Struct.new(:options).new({"author_names" => ["Joseph Heller"]})
          search_row(row(1, title: "Closing Time", authors: ["Someone Else"]), query: "catch-22")
          gate_decisions(FETCH)
          stub_search_fetch(-> { search_row(row(1, title: "Closing Time", authors: ["Someone Else"]), query: "catch-22 heller") })
          @book = bare

          assert_equal "no_match", execute.outcome
        end
      end
    end
  end
end
