# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsReimport
      class MatchEditionTest < ActiveSupport::TestCase
        Cand = Struct.new(:record)
        Fake = Struct.new(:response) do
          def call(**) = response
        end

        setup do
          @edition = ::Books::GoodreadsEdition.create!(goodreads_book_id: 90_001, signature: "me-sig", title: "War and Peace", primary_author: "Leo Tolstoy")
          @pick = books_books(:war_and_peace)
          @other = books_books(:crime_and_punishment)
          @key = "reimport:edition:#{@edition.id}"
        end

        def match(record: nil, candidates: [], decided_by: :rule, sources_failed: [])
          DataImporters::Match.new(outcome: record ? :matched : :unmatched, record: record, confidence: :high, decided_by: decided_by,
            candidates: candidates.map { |r| Cand.new(r) }, sources_failed: sources_failed)
        end

        def task_returning(book_id, confidence = "high", success: true)
          result = if success
            Services::Ai::Result.new(success: true, data: {book_id: book_id, confidence: confidence, reason: "because"})
          else
            Services::Ai::Result.new(success: false, error: "boom")
          end
          task = stub(call: result)
          klass = stub
          klass.stubs(:new).returns(task)
          klass
        end

        def run_match(finder_match, task_class)
          MatchEdition.call(edition: @edition, exclude_ids: Set.new, finder: Fake.new(finder_match), task_class: task_class)
        end

        def verdict = ::Books::RepairVerdict.find_by!(kind: :reimport_match, subject_key: @key)

        test "AI confirms the finder's match at high: matched and auto-approved" do
          result = run_match(match(record: @pick, candidates: [@other]), task_returning(@pick.id))

          assert_equal :matched, result.data[:outcome]
          assert verdict.approved?
          assert_equal "matched", verdict.payload["outcome"]
          assert_equal @pick.id, verdict.payload["book_id"]
          assert_equal [@pick.id, @other.id], verdict.payload["candidate_book_ids"]
          assert_equal({"answer" => @pick.id, "confidence" => "high", "reason" => "because"}, verdict.payload["ai"])
          assert_equal @edition.id, verdict.payload["goodreads_edition_id"]
          assert_equal 90_001, verdict.payload["goodreads_book_id"]
          assert verdict.payload["facts"].key?("full_title")
          assert verdict.confidence_high?
        end

        test "AI confirms the finder's match at medium: matched but proposed" do
          run_match(match(record: @pick), task_returning(@pick.id, "medium"))

          assert verdict.proposed?
          assert_equal @pick.id, verdict.payload["book_id"]
          assert verdict.confidence_medium?
        end

        test "AI confirms the finder's match at low: matched but proposed" do
          run_match(match(record: @pick), task_returning(@pick.id, "low"))

          assert verdict.proposed?
        end

        test "AI picks another candidate at high: matched but proposed" do
          run_match(match(record: @pick, candidates: [@other]), task_returning(@other.id))

          assert verdict.proposed?
          assert_equal @other.id, verdict.payload["book_id"]
        end

        test "AI picks a candidate when the finder found no match: proposed" do
          run_match(match(candidates: [@other]), task_returning(@other.id))

          assert verdict.proposed?
          assert_equal "matched", verdict.payload["outcome"]
        end

        test "AI says none and the finder was unmatched: create, auto-approved" do
          result = run_match(match(candidates: [@other]), task_returning(nil, "high"))

          assert_equal :create, result.data[:outcome]
          assert verdict.approved?
          assert_equal "create", verdict.payload["outcome"]
          assert_nil verdict.payload["book_id"]
        end

        test "AI says none but the finder matched: create, proposed" do
          run_match(match(record: @pick), task_returning(nil, "high"))

          assert verdict.proposed?
          assert_equal "create", verdict.payload["outcome"]
        end

        test "no candidates at all: create without asking the AI" do
          klass = mock
          klass.expects(:new).never

          result = run_match(match, klass)

          assert_equal :create, result.data[:outcome]
          assert verdict.approved?
          assert verdict.confidence_certain?
          assert verdict.decided_by_rule?
          assert_empty verdict.payload["candidate_book_ids"]
        end

        test "candidates without a record are skipped and the list stops at six" do
          extra = Array.new(7) { |i| ::Books::Book.create!(title: "Extra #{i}") }
          captured = nil
          task = stub(call: Services::Ai::Result.new(success: true, data: {book_id: nil, confidence: "low", reason: "r"}))
          klass = stub
          klass.stubs(:new).with { |args| captured = args[:books] }.returns(task)
          finder_match = DataImporters::Match.new(outcome: :unmatched, candidates: [Cand.new(nil)] + extra.map { |r| Cand.new(r) }, decided_by: :rule)

          run_match(finder_match, klass)

          assert_equal extra.first(6).map(&:id), captured.map(&:id)
        end

        test "an AI error records nothing and returns :retry" do
          result = run_match(match(record: @pick), task_returning(nil, success: false))

          assert_equal :retry, result.data[:outcome]
          assert_not ::Books::RepairVerdict.exists?(subject_key: @key)
        end

        test "a failed finder source or a fallback records nothing and returns :retry" do
          klass = mock
          klass.expects(:new).never

          assert_equal :retry, run_match(match(sources_failed: [:worldcat]), klass).data[:outcome]
          assert_equal :retry, run_match(match(decided_by: :fallback), klass).data[:outcome]
          assert_not ::Books::RepairVerdict.exists?(subject_key: @key)
        end

        test "an existing non-rejected verdict is kept without calling the finder" do
          existing = ::Books::RepairVerdict.create!(kind: :reimport_match, subject_key: @key, payload: {}, decided_by: :ai, status: :proposed, confidence: :low)
          finder = mock
          finder.expects(:call).never

          result = MatchEdition.call(edition: @edition, exclude_ids: Set.new, finder: finder)

          assert_equal :kept, result.data[:outcome]
          assert_equal existing, result.data[:verdict]
        end

        test "a current rejected verdict is left alone: no finder, no AI" do
          rejected = ::Books::RepairVerdict.create!(kind: :reimport_match, subject_key: @key, payload: {"x" => 1}, decided_by: :ai, status: :rejected, confidence: :low)
          finder = mock
          finder.expects(:call).never
          klass = mock
          klass.expects(:new).never

          result = MatchEdition.call(edition: @edition, exclude_ids: Set.new, finder: finder, task_class: klass)

          assert_equal :rejected, result.data[:outcome]
          assert_equal rejected, result.data[:verdict]
          assert_equal({"x" => 1}, rejected.reload.payload)
        end

        test "call without a finder builds the blinded one with the excluded ids" do
          x = @other.id
          DataImporters::Books::Book::Finder.expects(:new).with { |**kw|
            kw[:exclude_ids] == Set[x] && kw[:identifier_sources] == DataImporters::Books::Book::Finder::TRUSTED_IDENTIFIER_SOURCES
          }.returns(Fake.new(match))

          assert_equal :create, MatchEdition.call(edition: @edition, exclude_ids: Set[x]).data[:outcome]
        end

        test "the finder's record also listed among its candidates counts once" do
          run_match(match(record: @pick, candidates: [@pick, @other]), task_returning(@pick.id))

          assert_equal [@pick.id, @other.id], verdict.payload["candidate_book_ids"]
        end

        test "default_finder is blinded and passes the excluded mixed books through" do
          captured = nil
          DataImporters::Books::Book::Finder.stubs(:new).with { |**args| captured = args }.returns(:finder)

          assert_equal :finder, MatchEdition.default_finder(exclude_ids: Set[@other.id])
          assert_equal :none, captured[:open_library]
          assert_equal Set[@other.id], captured[:exclude_ids]
          assert_equal DataImporters::Books::Book::Finder::TRUSTED_IDENTIFIER_SOURCES, captured[:identifier_sources]
          assert_equal DataImporters::Books::Book::Finder::TRUSTED_ALTERNATE_TITLE_SOURCES, captured[:alternate_title_sources]
        end
      end
    end
  end
end
