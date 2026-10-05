require "test_helper"

module Services
  module Books
    module GoodreadsReplay
      class ResolveEditionTest < ActiveSupport::TestCase
        include GoodreadsImportHelper

        setup do
          @edition = goodreads_edition(title: "War and Peace", primary_author: "Leo Tolstoy")
          @book = books_books(:war_and_peace)
          @finder = stub("finder")
          @finder.stubs(:titles_agree?).returns(true)
          @finder.stubs(:creators_agree?).returns(true)
        end

        def finder_answers(record, decided_by: :ai, confidence: :medium, needs_review: true)
          decision = ::MatchDecision.create!(finder: "DataImporters::Books::Book::Finder", subject: @edition, record: record,
            outcome: record ? :matched : :unmatched, confidence: confidence, decided_by: decided_by, needs_review: needs_review)
          match = ::DataImporters::Match.new(outcome: record ? :matched : :unmatched, record: record, confidence: confidence,
            decided_by: decided_by, reason: "test", candidates: [], decision: decision, sources_failed: [])
          @finder.expects(:call).with(has_entries(verify: true, subject: @edition)).returns(match)
          match
        end

        test "runs the finder in verify mode and warms the edition cache with an agreeing match" do
          finder_answers(@book)

          result = ResolveEdition.call(edition: @edition, pass: 1, finder: @finder)

          refute result.data[:needs_full_pass]
          assert_equal @book, @edition.reload.book
          assert_predicate @edition, :matched?
          assert_predicate @edition, :verification_not_needed?
          refute_nil @edition.resolved_at
        end

        test "replay decisions never wait in the match-decision review queue" do
          match = finder_answers(@book)

          ResolveEdition.call(edition: @edition, pass: 1, finder: @finder)

          refute match.decision.reload.needs_review
        end

        test "an unmatched edition creates nothing and stays unresolved" do
          finder_answers(nil)

          assert_no_difference -> { ::Books::Book.count } do
            ResolveEdition.call(edition: @edition, pass: 2, finder: @finder)
          end
          assert_nil @edition.reload.resolved_at
        end

        test "an edition a member import already settled is left as that import left it" do
          other = books_books(:crime_and_punishment)
          @edition.update!(book: other, resolution: :created, verification: :verified, resolved_at: 1.day.ago)
          finder_answers(@book)

          ResolveEdition.call(edition: @edition, pass: 1, finder: @finder)

          assert_equal other, @edition.reload.book
          assert_predicate @edition, :created?
        end

        test "a failed AI call raises so the job retries, and records no findings" do
          import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete, legacy_import_id: 9)
          row = import.rows.create!(row_number: 1, goodreads_edition: @edition)
          match = finder_answers(nil, decided_by: :fallback, confidence: :low)

          assert_raises(ResolveEdition::MatchingFailed) { ResolveEdition.call(edition: @edition, pass: 1, finder: @finder) }
          assert_nil row.reload.replay_finding
          refute match.decision.reload.needs_review, "a failed AI call must not leave a decision in the review queue"
        end

        test "a final-pass disagreement with legacy does not warm the cache, so rejecting the relink leaves members unaffected" do
          import = ::Books::GoodreadsImport.create!(user: users(:regular_user), source: :legacy_replay, status: :complete, legacy_import_id: 10)
          import.rows.create!(row_number: 1, goodreads_edition: @edition)
          ::Identifier.create!(identifiable: @book, identifier_type: :books_work_goodreads_id, value: @edition.goodreads_book_id.to_s)
          finder_answers(books_books(:crime_and_punishment))

          result = ResolveEdition.call(edition: @edition, pass: 2, finder: @finder)

          assert_equal({disagrees: 1}, result.data[:tally])
          assert_nil @edition.reload.resolved_at
          assert_nil @edition.book_id
        end

        test "pass one uses the fast Open Library lookup and pass two adds /resolve" do
          assert_equal :identifiers, ResolveEdition.new(edition: @edition, pass: 1, finder: nil).send(:finder).instance_variable_get(:@open_library)
          assert_equal :all, ResolveEdition.new(edition: @edition, pass: 2, finder: nil).send(:finder).instance_variable_get(:@open_library)
        end
      end
    end
  end
end
