require "test_helper"

module DataImporters
  class AiSelectionTest < ActiveSupport::TestCase
    class FakeFinder
      def initialize(never_merge: [])
        @never_merge = never_merge
      end

      def never_merge?(a, b)
        @never_merge.any? { |pair| pair.sort_by(&:id) == [a, b].sort_by(&:id) }
      end
    end

    def setup
      @book = books_books(:war_and_peace)
      @other = books_books(:crime_and_punishment)
      @local = Candidate.new(record: @book, sources: [:opensearch], evidence: {title: "War and Peace", ranked_position: nil})
      @ranked = Candidate.new(record: @other, sources: [:opensearch], evidence: {title: "Crime and Punishment", ranked_position: 4})
      @external = Candidate.new(external_key: "OL1W", external_source: :open_library, sources: [:open_library], evidence: {title: "War and Peace"})
    end

    def select(shown, data, finder: FakeFinder.new)
      AiSelection.new(finder: finder, shown: shown, data: data).call
    end

    test "selecting a local candidate is a matched AI decision at the given confidence" do
      decision = select([@local, @external], {selected_index: 1, confidence: "high", reasoning: "Same work.", same_entity_groups: []})

      assert_equal [:matched, @book, :high, :ai, "Same work.", 1], [decision.outcome, decision.record, decision.confidence, decision.decided_by, decision.reason, decision.selected_index]
      assert_nil decision.external
    end

    test "selecting an external-only candidate is unmatched with that external set" do
      decision = select([@local, @external], {selected_index: 2, confidence: "medium", reasoning: "New here.", same_entity_groups: []})

      assert_equal [:unmatched, nil, :medium, :ai, 2], [decision.outcome, decision.record, decision.confidence, decision.decided_by, decision.selected_index]
      assert_equal @external, decision.external
    end

    test "selecting 0 is unmatched with no external" do
      decision = select([@local], {selected_index: 0, confidence: "low", reasoning: "Nothing fits.", same_entity_groups: []})

      assert_equal [:unmatched, nil, :low], [decision.outcome, decision.record, decision.confidence]
      assert_nil decision.external
      assert_nil decision.selected_index
    end

    test "a local candidate that also carries an external key keeps it as the external" do
      both = Candidate.new(record: @book, external_key: "OL1W", external_source: :open_library, sources: [:opensearch, :open_library], evidence: {title: "War and Peace"})

      decision = select([both], {selected_index: 1, confidence: "high", reasoning: "", same_entity_groups: []})

      assert_equal both, decision.external
    end

    test "a same-entity group of two local candidates becomes an :ai duplicate pair" do
      decision = select([@local, @ranked, @external], {selected_index: 3, confidence: "high", reasoning: "", same_entity_groups: [[1, 2], [1, 3]]})

      assert_equal [[@book, @other, :ai]], decision.duplicate_pairs
    end

    test "when the selected local candidate is in a group with a ranked one, the ranked one wins and the reason says so" do
      decision = select([@local, @ranked], {selected_index: 1, confidence: "high", reasoning: "Picked the first.", same_entity_groups: [[1, 2]]})

      assert_equal @other, decision.record
      assert_equal 2, decision.selected_index
      assert_match(/Preferred ranked #4/, decision.reason)
      assert_equal [[@book, @other, :ai]], decision.duplicate_pairs
    end

    test "the ranked switch and the pair are skipped for a pair a human ruled not a duplicate" do
      finder = FakeFinder.new(never_merge: [[@book, @other]])

      decision = select([@local, @ranked], {selected_index: 1, confidence: "high", reasoning: "Picked the first.", same_entity_groups: [[1, 2]]}, finder: finder)

      assert_equal @book, decision.record
      assert_equal [], decision.duplicate_pairs
    end

    test "a selected candidate that is itself ranked is never switched" do
      decision = select([@ranked, @local], {selected_index: 1, confidence: "high", reasoning: "", same_entity_groups: [[1, 2]]})

      assert_equal @other, decision.record
    end
  end
end
