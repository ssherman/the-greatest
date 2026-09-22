require "test_helper"

module DataImporters
  class MatchTest < ActiveSupport::TestCase
    test "matched? and unmatched? read the outcome" do
      assert Match.new(outcome: :matched, record: books_books(:war_and_peace)).matched?
      assert Match.new(outcome: :unmatched).unmatched?
      assert_not Match.new(outcome: :unmatched).matched?
    end

    test "needs_review? is true for medium or low confidence and for a fallback decision" do
      assert Match.new(outcome: :matched, confidence: :medium, decided_by: :ai).needs_review?
      assert Match.new(outcome: :unmatched, confidence: :low, decided_by: :ai).needs_review?
      assert Match.new(outcome: :unmatched, confidence: :low, decided_by: :fallback).needs_review?
      assert_not Match.new(outcome: :matched, confidence: :certain, decided_by: :identifier).needs_review?
      assert_not Match.new(outcome: :unmatched, confidence: :high, decided_by: :rule).needs_review?
    end

    test "defaults candidates and sources_failed to empty arrays" do
      match = Match.new(outcome: :unmatched)

      assert_equal [], match.candidates
      assert_equal [], match.sources_failed
    end
  end
end
