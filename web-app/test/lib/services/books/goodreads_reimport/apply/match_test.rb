# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      module Apply
        class MatchTest < ActiveSupport::TestCase
          include GoodreadsImportHelper

          setup do
            stub_resolution_services
            @user = users(:editor_user)
            @import = ::Books::GoodreadsImport.create!(user: @user, source: :legacy_replay, status: :complete, finished_at: Time.current)
            @edition = goodreads_edition(goodreads_book_id: 91_000_001, isbn13: "9780441013593", original_publication_year: 1977)
          end

          def verdict(outcome:, book_id: nil, **extra)
            ::Books::RepairVerdict.create!(kind: :reimport_match, subject_key: "reimport:edition:#{@edition.id}", decided_by: :ai, status: :approved,
              payload: {"goodreads_edition_id" => @edition.id, "outcome" => outcome, "book_id" => book_id}.merge(extra))
          end

          def row_in(import)
            import.rows.create!(row_number: import.rows.count + 1, goodreads_edition: @edition)
          end

          test "matched writes the decision into the shared edition cache over what legacy cached" do
            @edition.update!(book: books_books(:crime_and_punishment), resolution: :created, resolved_at: 1.day.ago)

            result = Match.call(verdict: verdict(outcome: "matched", book_id: books_books(:war_and_peace).id))

            @edition.reload
            assert_equal :applied, result.data[:outcome]
            assert_equal [books_books(:war_and_peace), true], [@edition.book, @edition.matched?]
            assert @edition.resolved_at.present?
          end

          test "matched is applied, changing nothing, when the edition already caches that book" do
            cached = @edition.tap { |edition| edition.update!(book: books_books(:war_and_peace), resolution: :matched, resolved_at: Time.current) }
            verdict = verdict(outcome: "matched", book_id: books_books(:war_and_peace).id)

            assert_equal :applied, Match.call(verdict: verdict).data[:outcome]
            assert_equal "book_id", verdict.reload.payload["edition_before"].keys.first
            assert_equal cached.book_id, @edition.reload.book_id
          end

          test "matched follows a book merged away" do
            gone = ::Books::Book.create!(title: "Gone #{SecureRandom.hex(3)}")
            target = books_books(:war_and_peace)
            ::Books::RepairVerdict.create!(kind: :merge_books, subject_key: "books:gone", decided_by: :rule, status: :approved,
              payload: {"source_id" => gone.id, "target_id" => target.id})
            gone_id = gone.id
            gone.destroy!

            Match.call(verdict: verdict(outcome: "matched", book_id: gone_id))

            assert_equal target, @edition.reload.book
          end

          test "matched with a book that is gone is a no-op" do
            assert_equal :noop, Match.call(verdict: verdict(outcome: "matched", book_id: 0)).data[:outcome]
            assert_nil @edition.reload.book_id
          end

          test "create makes a non-provisional book and caches it on the edition" do
            row_in(@import)
            verdict = verdict(outcome: "create")

            result = Match.call(verdict: verdict)

            book = @edition.reload.book
            assert_equal :applied, result.data[:outcome]
            assert_equal [false, true], [book.provisional?, @edition.created?]
            assert_equal book.id, verdict.reload.payload["created_book_id"]
            assert_equal [false], book.authors.map(&:provisional?)
          end

          test "create on an edition legacy already settled on another book makes a new book and remembers the old cache" do
            old = books_books(:crime_and_punishment)
            @edition.update!(book: old, resolution: :created, resolved_at: 1.day.ago, verification: :unverified)
            row_in(@import)
            verdict = verdict(outcome: "create")

            result = Match.call(verdict: verdict)

            made = @edition.reload.book
            assert_equal :applied, result.data[:outcome]
            assert_not_equal old, made
            assert_equal [false, made.id], [made.provisional?, verdict.reload.payload["created_book_id"]]
            assert_equal old.id, verdict.payload["edition_before"]["book_id"]
          end

          test "create that would only return a cached book is a no-op and restores the cache" do
            old = books_books(:crime_and_punishment)
            @edition.update!(book: old, resolution: :created, resolved_at: 1.day.ago)
            row_in(@import)
            ::Services::Books::GoodreadsImports::CreateBook.stubs(:call).returns(stub(data: {outcome: :cached}))
            verdict = verdict(outcome: "create")

            result = Match.call(verdict: verdict)

            assert_equal :noop, result.data[:outcome]
            assert_nil verdict.reload.payload["created_book_id"]
            assert_equal old, @edition.reload.book
          end

          test "create adopting the old cache is refused and rolled back" do
            old = books_books(:crime_and_punishment)
            @edition.update!(book: old, resolution: :created, resolved_at: 1.day.ago)
            row_in(@import)
            edition = @edition
            ::Services::Books::GoodreadsImports::CreateBook.stubs(:call).with do
              edition.update!(book: old, resolution: :created, resolved_at: Time.current)
              true
            end.returns(stub(data: {outcome: :matched}))
            verdict = verdict(outcome: "create")

            assert_equal :noop, Match.call(verdict: verdict).data[:outcome]
            assert_equal [old.id, nil], [@edition.reload.book_id, verdict.reload.payload["created_book_id"]]
          end

          test "create never adopts a same-signature book the check turned down" do
            turned_down = books_books(:crime_and_punishment)
            goodreads_edition(goodreads_book_id: 91_000_099, book: turned_down, resolution: :created, resolved_at: 1.day.ago)
            row_in(@import)
            verdict = verdict(outcome: "create", candidate_book_ids: [turned_down.id])

            result = Match.call(verdict: verdict)

            assert_equal :applied, result.data[:outcome]
            assert_not_equal turned_down.id, verdict.reload.payload["created_book_id"]
            assert_equal verdict.payload["created_book_id"], @edition.reload.book_id
          end

          test "an adopt of a turned-down candidate is refused even if CreateBook returns it" do
            turned_down = books_books(:crime_and_punishment)
            row_in(@import)
            edition = @edition
            ::Services::Books::GoodreadsImports::CreateBook.stubs(:call).with do
              edition.update!(book: turned_down, resolution: :created, resolved_at: Time.current)
              true
            end.returns(stub(data: {outcome: :matched}))
            verdict = verdict(outcome: "create", candidate_book_ids: [turned_down.id])

            result = Match.call(verdict: verdict)

            assert_equal :noop, result.data[:outcome]
            assert_nil @edition.reload.book_id
          end

          test "edition_before keeps the decision and pending import too" do
            decision = ::MatchDecision.create!(finder: "X", subject: @edition, outcome: :unmatched, confidence: :high, decided_by: :rule)
            @edition.update!(match_decision: decision, book: books_books(:crime_and_punishment), resolution: :created, resolved_at: 1.day.ago)
            verdict = verdict(outcome: "matched", book_id: books_books(:war_and_peace).id)

            Match.call(verdict: verdict)

            assert_equal decision.id, verdict.reload.payload["edition_before"]["match_decision_id"]
          end

          test "a parked edition is not created" do
            @edition.update!(resolution: :parked, resolved_at: Time.current)
            row_in(@import)
            ::Services::Books::GoodreadsImports::CreateBook.expects(:call).never

            result = Match.call(verdict: verdict(outcome: "create"))

            assert_equal [:noop, "edition parked"], [result.data[:outcome], result.data[:reason]]
          end

          test "matched records the cache it replaced" do
            @edition.update!(book: books_books(:crime_and_punishment), resolution: :created, resolved_at: 1.day.ago)
            verdict = verdict(outcome: "matched", book_id: books_books(:war_and_peace).id)

            Match.call(verdict: verdict)

            assert_equal books_books(:crime_and_punishment).id, verdict.reload.payload["edition_before"]["book_id"]
          end

          test "create records the book against the newest in-scope import of the edition" do
            older = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete, finished_at: 2.days.ago)
            row_in(older)
            row_in(@import)
            ::Services::Books::GoodreadsImports::CreateBook.expects(:call)
              .with { |args| args[:import] == @import && args[:provisional] == false && args[:match].unmatched? }
              .returns(stub(data: {outcome: :created}))

            Match.call(verdict: verdict(outcome: "create"))
          end

          test "create is applied, creating nothing, when an earlier apply already stored the book" do
            row_in(@import)
            verdict = verdict(outcome: "create", created_book_id: books_books(:war_and_peace).id)
            ::Services::Books::GoodreadsImports::CreateBook.expects(:call).never

            assert_equal :applied, Match.call(verdict: verdict).data[:outcome]
          end

          test "create with no in-scope row is a no-op and creates nothing" do
            ::Services::Books::GoodreadsImports::CreateBook.expects(:call).never

            result = Match.call(verdict: verdict(outcome: "create"))

            assert_equal :noop, result.data[:outcome]
          end

          test "an applied verdict is a no-op" do
            verdict = verdict(outcome: "matched", book_id: books_books(:war_and_peace).id)
            verdict.update_columns(applied_at: Time.current)

            assert_equal :noop, Match.call(verdict: verdict).data[:outcome]
            assert_nil @edition.reload.book_id
          end
        end
      end
    end
  end
end
