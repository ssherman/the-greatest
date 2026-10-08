# frozen_string_literal: true

require "test_helper"

module Recommendations
  class ExplainerTest < ActiveSupport::TestCase
    def setup
      @profile = Profile.new(genres: [[10, 2.5], [11, 0.4]], subjects: [[20, 1.8]], locations: [], demoted: [],
        fiction_share: nil, genre_distribution: {}, counts: {})
      @config = Config.resolve
    end

    def fact(id, type = "genre")
      CategoryFact.new(id: id, category_type: type, item_count: 1)
    end

    def explain(evidence: {taste: true}, categories: [], rank: 37)
      Explainer.call(candidate: Candidate.new(item_id: 1, score: 1.0, rank_position: rank, evidence: evidence),
        profile: @profile, categories: categories, config: @config)
    end

    test "because_of wins when the collaborative evidence names a book" do
      assert_equal Reason.new(type: :because_of, ids: [99]), explain(evidence: {because_of: 99}, categories: [fact(10)])
    end

    test "interests names the two strongest profile categories above the threshold" do
      reason = explain(categories: [fact(11), fact(20, "subject"), fact(10), fact(30)])
      assert_equal Reason.new(type: :interests, ids: [10, 20]), reason, "11 is below explain_threshold; 30 is not in the profile"
    end

    test "falls back to the rank when no category clears the threshold" do
      assert_equal Reason.new(type: :ranked, ids: [37]), explain(categories: [fact(11)])
      assert_equal Reason.new(type: :ranked, ids: []), explain(categories: [], rank: nil)
    end
  end
end
