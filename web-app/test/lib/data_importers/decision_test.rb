require "test_helper"

module DataImporters
  class DecisionTest < ActiveSupport::TestCase
    test "fallback is an unmatched, low-confidence, fallback-decided decision carrying the reason" do
      decision = Decision.fallback("AI selection failed: boom")

      assert_equal [:unmatched, nil, :low, :fallback], [decision.outcome, decision.record, decision.confidence, decision.decided_by]
      assert_equal "AI selection failed: boom", decision.reason
      assert_nil decision.external
      assert_nil decision.selected_index
      assert_equal [], decision.duplicate_pairs
    end

    test "duplicate_pairs defaults to an empty array and keeps a given list" do
      assert_equal [], Decision.new(outcome: :matched).duplicate_pairs
      pairs = [[books_books(:war_and_peace), books_books(:crime_and_punishment), :ai]]
      assert_equal pairs, Decision.new(outcome: :matched, duplicate_pairs: pairs).duplicate_pairs
    end
  end
end
