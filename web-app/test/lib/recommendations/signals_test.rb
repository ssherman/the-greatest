# frozen_string_literal: true

require "test_helper"

module Recommendations
  class SignalsTest < ActiveSupport::TestCase
    def setup
      @adapter = mock("adapter")
      @config = Config.resolve
      @criteria = ::Books::RecommendationCriteria.new({})
      @profile = Profile.new(genres: [[1, 2.0]], subjects: [], locations: [], demoted: [], fiction_share: nil,
        genre_distribution: {}, counts: {})
      @empty = Profile.new(genres: [], subjects: [], locations: [], demoted: [], fiction_share: nil,
        genre_distribution: {}, counts: {})
    end

    def call(signal, profile: @profile)
      signal.call(profile: profile, interactions: [], criteria: @criteria, excluded_ids: [7], size: 50)
    end

    test "taste profile delegates to the adapter and is empty for an empty profile" do
      signal = Signals::TasteProfile.new(adapter: @adapter, config: @config)
      @adapter.expects(:search_candidates).with(profile: @profile, criteria: @criteria, excluded_ids: [7], size: 50)
        .returns([Candidate.new(item_id: 1, score: 1.0, rank_position: nil, evidence: {taste: true})])
      assert_equal [1], call(signal).map(&:item_id)
      assert_equal [], call(signal, profile: @empty)
      assert signal.available?
      assert_equal 1.0, signal.weight(3)
      assert_equal :taste_profile, signal.name
    end

    test "rank only delegates to the adapter regardless of profile" do
      signal = Signals::RankOnly.new(adapter: @adapter, config: @config)
      @adapter.expects(:rank_ordered_candidates).with(criteria: @criteria, excluded_ids: [7], size: 50)
        .returns([Candidate.new(item_id: 2, score: 0.0, rank_position: 1, evidence: {})])
      assert_equal [2], call(signal, profile: @empty).map(&:item_id)
    end

    test "collaborative is unavailable, returns nothing, and its weight ramps with history" do
      signal = Signals::Collaborative.new(adapter: @adapter, config: @config)
      assert_not signal.available?
      assert_equal [], call(signal)
      assert_in_delta 0.0, signal.weight(0), 0.001
      assert_in_delta 0.5, signal.weight(10), 0.001
      assert_in_delta 200.0 / 210, signal.weight(200), 0.001
    end
  end
end
