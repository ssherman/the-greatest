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

          test "a match corrected after the apply run loaded it applies the corrected book" do
            stale = verdict(outcome: "matched", book_id: books_books(:crime_and_punishment).id)
            ::Books::RepairVerdict.find(stale.id).update!(payload: stale.payload.merge("book_id" => books_books(:war_and_peace).id))

            assert_equal :applied, Match.call(verdict: stale).data[:outcome]
            assert_equal books_books(:war_and_peace).id, @edition.reload.book_id
            assert_equal books_books(:war_and_peace).id, stale.reload.payload["book_id"]
          end

          test "a match rejected or superseded after the apply run loaded it is left alone" do
            [{status: :rejected}, {superseded_at: Time.current}].each do |change|
              ::Books::RepairVerdict.where(subject_key: "reimport:edition:#{@edition.id}").delete_all
              stale = verdict(outcome: "matched", book_id: books_books(:war_and_peace).id)
              ::Books::RepairVerdict.find(stale.id).update!(change)

              result = Match.call(verdict: stale)

              assert_equal :noop, result.data[:outcome], change.keys.inspect
              refute result.data[:final], change.keys.inspect
              assert_nil @edition.reload.book_id, change.keys.inspect
            end
          end

          test "matched is applied, changing nothing, when the edition already caches that book" do
            cached = @edition.tap { |edition| edition.update!(book: books_books(:war_and_peace), resolution: :matched, resolved_at: Time.current) }
            verdict = verdict(outcome: "matched", book_id: books_books(:war_and_peace).id)

            assert_equal :applied, Match.call(verdict: verdict).data[:outcome]
            assert_equal "book_id", verdict.reload.payload["edition_before"].keys.first
            assert_equal cached.book_id, @edition.reload.book_id
          end

          test "an applied match records a strip for every other book holding the edition's real identifiers as legacy" do
            @edition.update!(isbn10: "0441013597")
            war = books_books(:war_and_peace)
            other = books_books(:crime_and_punishment)
            [war, other].each { |book| book.identifiers.where(identifier_type: %i[books_work_isbn13 books_work_isbn10 books_work_goodreads_id]).delete_all }
            on_other = [[:books_work_isbn13, "9780441013593"], [:books_work_isbn10, "0441013597"], [:books_work_goodreads_id, "91000001"]].map do |type, value|
              Identifier.create!(identifiable: other, identifier_type: type, value: value, source: :legacy)
            end
            Identifier.create!(identifiable: war, identifier_type: :books_work_isbn13, value: "9780441013593", source: :legacy)

            Match.call(verdict: verdict(outcome: "matched", book_id: war.id))

            strips = ::Books::RepairVerdict.reimport_strip.order(:id)
            assert_equal on_other.map { |identifier| [other.id, identifier.identifier_type, identifier.value] }.sort,
              strips.map { |strip| strip.payload.values_at("book_id", "identifier_type", "value") }.sort
            strip = strips.first
            assert_equal [true, "rule", nil, @edition.id], [strip.approved?, strip.decided_by, strip.payload["because_row_key"], strip.payload["because_edition_id"]]
          end

          test "no strip for an identifier another book holds from a source other than legacy," do
            other = books_books(:crime_and_punishment)
            other.identifiers.where(identifier_type: :books_work_isbn13).delete_all
            Identifier.create!(identifiable: other, identifier_type: :books_work_isbn13, value: "9780441013593", source: :open_library)

            Match.call(verdict: verdict(outcome: "matched", book_id: books_books(:war_and_peace).id))

            assert_equal 0, ::Books::RepairVerdict.reimport_strip.count
          end

          test "a created book strips the legacy copies of its identifiers from other books" do
            other = books_books(:crime_and_punishment)
            other.identifiers.where(identifier_type: :books_work_isbn13).delete_all
            Identifier.create!(identifiable: other, identifier_type: :books_work_isbn13, value: "9780441013593", source: :legacy)
            row_in(@import)

            Match.call(verdict: verdict(outcome: "create"))

            assert_equal [other.id], ::Books::RepairVerdict.reimport_strip.map { |strip| strip.payload["book_id"] }
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

          test "create records the authors it created, so their enrichment can be queued" do
            row_in(@import)
            verdict = verdict(outcome: "create")

            Match.call(verdict: verdict)

            book = @edition.reload.book
            assert_not_empty book.authors
            assert_equal book.authors.map(&:id).sort, verdict.reload.payload["created_author_ids"].sort
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
