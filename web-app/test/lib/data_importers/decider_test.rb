require "test_helper"

module DataImporters
  class DeciderTest < ActiveSupport::TestCase
    # A stand-in for the finder: the four judgements the rules ask it for.
    class FakeFinder
      def initialize(corroborated: true, exact: false, ranked_ids: [], list_counts: {})
        @corroborated = corroborated
        @exact = exact
        @ranked_ids = ranked_ids
        @list_counts = list_counts
      end

      def corroborated?(_query, candidate)
        @corroborated.respond_to?(:call) ? @corroborated.call(candidate) : @corroborated
      end

      def exact_match?(_query, candidate)
        @exact.respond_to?(:call) ? @exact.call(candidate) : @exact
      end

      def ranked?(record) = @ranked_ids.include?(record.id)

      def list_count(record) = @list_counts.fetch(record.id, 0)
    end

    def setup
      @book = books_books(:war_and_peace)
      @other = books_books(:crime_and_punishment)
      @third = books_books(:combo_steinbeck)
      @query = {title: "War and Peace"}
    end

    def decide(candidates, finder: FakeFinder.new, verify: false, sources_run: 2)
      Decider.new(finder: finder, query: @query, candidates: candidates, verify: verify, sources_run: sources_run).call
    end

    def identifier_candidate(record, type: "books_work_isbn13", value: "978")
      Candidate.new(record: record, sources: [:identifier], evidence: {matched_identifier: {type: type, value: value}})
    end

    test "rule 0: a legacy candidate is a certain rule match" do
      decision = decide([Candidate.new(record: @book, sources: [:legacy], decisive: true)])

      assert_equal [:matched, @book, :certain, :rule], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
      assert_match(/legacy/, decision.reason)
    end

    test "rule 0 does not fire under verify, so a lone legacy candidate goes to the AI" do
      assert_nil decide([Candidate.new(record: @book, sources: [:legacy], decisive: true)], verify: true)
    end

    test "rule 1: a corroborated identifier hit is a certain identifier match" do
      decision = decide([identifier_candidate(@book)])

      assert_equal [:matched, @book, :certain, :identifier], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
      assert_match(/books_work_isbn13 978/, decision.reason)
      assert_equal [], decision.duplicate_pairs
    end

    test "rule 1: an uncorroborated identifier hit is not decisive and, alone, goes to the AI" do
      finder = FakeFinder.new(corroborated: false, exact: false)

      assert_nil decide([identifier_candidate(@book)], finder: finder)
    end

    test "rule 1 does not fire under verify" do
      assert_nil decide([identifier_candidate(@book)], verify: true)
    end

    test "rule 1: several corroborated hits prefer the ranked record and flag the others as identifier collisions" do
      finder = FakeFinder.new(ranked_ids: [@other.id])

      decision = decide([identifier_candidate(@book), identifier_candidate(@other)], finder: finder)

      assert_equal @other, decision.record
      assert_equal [[@other, @book, :identifier_collision]], decision.duplicate_pairs
    end

    test "rule 1: with no ranked record, the one on more lists wins, then the lowest id" do
      by_lists = FakeFinder.new(list_counts: {@book.id => 1, @other.id => 4})
      assert_equal @other, decide([identifier_candidate(@book), identifier_candidate(@other)], finder: by_lists).record

      tie = FakeFinder.new
      low, high = [@book, @other].sort_by(&:id)
      assert_equal low, decide([identifier_candidate(high), identifier_candidate(low)], finder: tie).record
    end

    test "rule 2: a local candidate the external source accepted, corroborated, is a certain match" do
      candidate = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "accept"})

      decision = decide([candidate])

      assert_equal [:matched, @book, :certain, :identifier], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
      assert_equal candidate, decision.external
    end

    test "rule 2 needs corroboration and does not fire under verify" do
      candidate = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "accept"})

      assert_nil decide([candidate], finder: FakeFinder.new(corroborated: false))
      assert_nil decide([candidate], verify: true)
    end

    test "rule 2: several locals holding the accepted key prefer the ranked one and flag the rest as external key collisions" do
      first = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "accept"})
      second = Candidate.new(record: @other, external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "accept"})
      finder = FakeFinder.new(ranked_ids: [@other.id])

      decision = decide([first, second], finder: finder)

      assert_equal @other, decision.record
      assert_equal second, decision.external
      assert_equal [[@other, @book, :external_key_collision]], decision.duplicate_pairs
    end

    test "rule 3: no candidates is a high-confidence unmatched, naming how many sources ran" do
      decision = decide([], sources_run: 3)

      assert_equal [:unmatched, nil, :high, :rule], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
      assert_match(/3 sources/, decision.reason)
    end

    test "rule 4: exactly one local candidate that matches exactly is a high-confidence rule match" do
      decision = decide([Candidate.new(record: @book, sources: [:exact])], finder: FakeFinder.new(exact: true))

      assert_equal [:matched, @book, :high, :rule], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
    end

    test "rule 4 fires when exactly one of several local candidates matches exactly" do
      finder = FakeFinder.new(exact: ->(candidate) { candidate.record == @book })

      decision = decide([Candidate.new(record: @other, sources: [:opensearch]), Candidate.new(record: @book, sources: [:exact])], finder: finder)

      assert_equal [:matched, @book, :high, :rule], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
    end

    test "rule 4 does not fire for two exact local candidates, or for one that is not exact" do
      assert_nil decide([Candidate.new(record: @book, sources: [:exact]), Candidate.new(record: @other, sources: [:exact])], finder: FakeFinder.new(exact: true))
      assert_nil decide([Candidate.new(record: @book, sources: [:opensearch])], finder: FakeFinder.new(exact: false))
    end

    test "rule 4 does not fire while another local candidate carries an uncorroborated identifier hit: the AI decides" do
      finder = FakeFinder.new(corroborated: false, exact: ->(candidate) { candidate.record == @book })

      assert_nil decide([identifier_candidate(@other), Candidate.new(record: @book, sources: [:exact])], finder: finder)
    end

    test "rule 4 still fires when the one exact local candidate is itself an uncorroborated identifier hit (verify skips rule 1)" do
      finder = FakeFinder.new(corroborated: false, exact: true)

      decision = decide([identifier_candidate(@book)], finder: finder, verify: true)

      assert_equal [:matched, @book, :high, :rule], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
    end

    test "rule 4 still fires under verify" do
      decision = decide([Candidate.new(record: @book, sources: [:exact])], finder: FakeFinder.new(exact: true), verify: true)

      assert_equal :matched, decision.outcome
    end

    test "rule 5: only external candidates, one accepted, is a high-confidence unmatched with that external set" do
      accepted = Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "accept"})
      other = Candidate.new(external_key: "OL2W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "reject"})

      decision = decide([other, accepted])

      assert_equal [:unmatched, nil, :high, :rule], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
      assert_equal accepted, decision.external
    end

    test "rule 5 does not fire when a local candidate is also present" do
      accepted = Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "accept"})

      assert_nil decide([Candidate.new(record: @book, sources: [:opensearch]), accepted])
    end

    test "rule 6: anything else is nil" do
      assert_nil decide([Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {external_verdict: "abstain"})])
    end
  end
end
