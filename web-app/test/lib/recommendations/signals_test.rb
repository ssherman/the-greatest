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

    def model_with(rows)
      model = RecommendationModel.create!(domain: "books", version: "v", state: :active)
      rows.each { |i, n, w| model.recommendation_item_neighbors.create!(item_id: i, neighbor_id: n, weight: w) }
      model
    end

    def shelf(*entries)
      entries.map { |id, kind, rating| Interaction.new(item_id: id, weight: 1.0, kind: kind, rating: rating) }
    end

    test "collaborative weight ramps with history and it is unavailable without a model or when switched off" do
      @adapter.stubs(:domain).returns(:books)
      signal = Signals::Collaborative.new(adapter: @adapter, config: @config)
      assert_not signal.available?
      assert_in_delta 0.0, signal.weight(0), 0.001
      assert_in_delta 0.5, signal.weight(10), 0.001
      assert_in_delta 200.0 / 210, signal.weight(200), 0.001

      model_with([])
      assert Signals::Collaborative.new(adapter: @adapter, config: @config).available?
      assert_not Signals::Collaborative.new(adapter: @adapter, config: Config.resolve(collaborative: false)).available?
      assert_equal :collaborative, signal.name
    end

    test "a model for another domain leaves the books signal unavailable" do
      @adapter.stubs(:domain).returns(:books)
      RecommendationModel.create!(domain: "music", version: "v", state: :active)
      assert_not Signals::Collaborative.new(adapter: @adapter, config: @config).available?
    end

    test "collaborative is unavailable, not fatal, when the model lookup raises" do
      @adapter.stubs(:domain).returns(:books)
      RecommendationModel.stubs(:active_for).raises(StandardError, "db down")
      assert_not Signals::Collaborative.new(adapter: @adapter, config: @config).available?
    end

    test "a read and loved book is named as the contributor" do
      @adapter.stubs(:domain).returns(:books)
      model_with([[5, 14, 0.8], [1, 14, 0.1]])
      @adapter.stubs(:filter_candidate_ids).returns({14 => 2})
      out = Signals::Collaborative.new(adapter: @adapter, config: @config)
        .call(profile: @profile, interactions: shelf([5, :read, 4], [1, :favorite, nil]), criteria: @criteria, excluded_ids: [], size: 50)
      assert_equal [14], out.map(&:item_id)
      assert_equal 5, out[0].evidence[:because_of]
    end

    test "collaborative scores the trainable shelf, filters through the pool, and names a loved contributor" do
      @adapter.stubs(:domain).returns(:books)
      model_with([[1, 10, 0.5], [1, 11, 0.2], [2, 10, 0.4], [2, 12, 0.9], [3, 13, 0.3]])
      # 1 favorite, 2 read + rated 3, 3 want-to-read (never scored), 4 rated 2 (never scored)
      interactions = shelf([1, :favorite, nil], [2, :read, 3], [3, :want_to_read, nil], [4, :review, 2])
      @adapter.expects(:filter_candidate_ids).with([10, 12, 11], criteria: @criteria, excluded_ids: [7])
        .returns({12 => 40, 10 => 3})

      out = Signals::Collaborative.new(adapter: @adapter, config: @config)
        .call(profile: @profile, interactions: interactions, criteria: @criteria, excluded_ids: [7], size: 50)

      assert_equal [10, 12], out.map(&:item_id), "11 did not survive the pool filter; 10 and 12 tie at 0.9 and the lower id comes first"
      assert_equal [3, 40], out.map(&:rank_position)
      assert_in_delta 0.9, out[0].score, 1e-9
      assert_equal 1, out[0].evidence[:because_of], "item 1 (a favorite) contributed 0.5 to item 10, more than item 2's 0.4"
      assert_in_delta 0.5, out[0].evidence[:term], 1e-9
      assert_nil out[1].evidence[:because_of], "item 2 contributed all of item 12's score but is read + rated 3, below because_of_rating"
      assert_in_delta 0.9, out[1].evidence[:term], 1e-9
    end

    test "collaborative over-fetches by the knob and truncates to size" do
      @adapter.stubs(:domain).returns(:books)
      model = model_with([])
      (1..10).each { |n| model.recommendation_item_neighbors.create!(item_id: 1, neighbor_id: 100 + n, weight: 1.0 / n) }
      NeighborScores.expects(:call).with(model: model, shelf_ids: [1], excluded_ids: [], limit: 6).returns(
        (1..6).map { |n| {item_id: 100 + n, score: 1.0 / n, because_of: 1, term: 1.0 / n} }
      )
      @adapter.stubs(:filter_candidate_ids).returns((1..6).to_h { |n| [100 + n, n] })
      out = Signals::Collaborative.new(adapter: @adapter, config: @config)
        .call(profile: @profile, interactions: shelf([1, :favorite, nil]), criteria: @criteria, excluded_ids: [], size: 3)
      assert_equal [101, 102, 103], out.map(&:item_id)
    end

    test "collaborative returns nothing for a shelf with no positives and never queries" do
      @adapter.stubs(:domain).returns(:books)
      model_with([[3, 13, 0.3]])
      NeighborScores.expects(:call).never
      @adapter.expects(:filter_candidate_ids).never
      out = Signals::Collaborative.new(adapter: @adapter, config: @config)
        .call(profile: @profile, interactions: shelf([3, :want_to_read, nil], [4, :review, 1]), criteria: @criteria, excluded_ids: [], size: 50)
      assert_equal [], out
    end
  end
end
