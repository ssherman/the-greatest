# frozen_string_literal: true

require "test_helper"

module Recommendations
  class FusionTest < ActiveSupport::TestCase
    def cand(id, rank: nil, evidence: {})
      Candidate.new(item_id: id, score: 1.0, rank_position: rank, evidence: evidence)
    end

    def fuse(lists, **overrides)
      Fusion.call(lists: lists, config: Config.resolve({rank_prior_weight: 0.0}.merge(overrides)))
    end

    test "reciprocal rank fusion sums weight over k plus rank" do
      fused = fuse([
        {weight: 1.0, candidates: [cand(1), cand(2)]},
        {weight: 0.5, candidates: [cand(2), cand(3)]}
      ])
      assert_equal [2, 1, 3], fused.map(&:item_id)
      assert_in_delta 1.0 / 62 + 0.5 / 61, fused.first.score, 1e-9
    end

    test "a zero-weight list contributes nothing" do
      fused = fuse([{weight: 1.0, candidates: [cand(1)]}, {weight: 0.0, candidates: [cand(2), cand(3)]}])
      assert_equal [1, 2, 3], fused.map(&:item_id)
      assert_in_delta 0.0, fused.last.score, 1e-12
    end

    test "the rank prior re-orders ties toward the better global rank" do
      fused = fuse([{weight: 1.0, candidates: [cand(1, rank: 500)]}, {weight: 1.0, candidates: [cand(2, rank: 5)]}],
        rank_prior_weight: 0.3)
      assert_equal [2, 1], fused.map(&:item_id)
    end

    test "the rank prior never outweighs a clear personalized preference" do
      fused = fuse([{weight: 1.0, candidates: [cand(1, rank: 9000), cand(3), cand(4), cand(2, rank: 1)]}], rank_prior_weight: 0.3)
      assert_equal 1, fused.first.item_id, "three places of taste ordering beat a 0.3-weight prior"
    end

    test "evidence is merged across lists" do
      fused = fuse([
        {weight: 1.0, candidates: [cand(1, evidence: {taste: true})]},
        {weight: 1.0, candidates: [cand(1, evidence: {because_of: 9})]}
      ])
      assert_equal({taste: true, because_of: 9}, fused.first.evidence)
    end
  end
end
