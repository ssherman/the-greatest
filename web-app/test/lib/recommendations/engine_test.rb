# frozen_string_literal: true

require "test_helper"

module Recommendations
  class EngineTest < ActiveSupport::TestCase
    Item = Struct.new(:id)

    # A complete in-memory adapter so the engine's orchestration is tested
    # without Postgres or OpenSearch. Every public adapter method is here.
    class FakeAdapter
      attr_reader :calls

      def initialize(config:, interactions: [], categories: {}, candidates: [], ranked: [], facts: {}, raise_search: false, raise_ranked: false, missing_ids: [])
        @config = config
        @interactions = interactions
        @categories = categories
        @candidates = candidates
        @ranked = ranked
        @facts = facts
        @raise_search = raise_search
        @raise_ranked = raise_ranked
        @missing_ids = missing_ids
        @calls = []
      end

      def interactions(_user) = @interactions

      def shelved_item_ids(_user) = @interactions.map(&:item_id)

      def categories_for(ids) = @categories.slice(*ids)

      def catalog_size = 1000

      def type_category_ids = {"Fiction" => 1, "Nonfiction" => 2}

      def criteria_for(_user) = ::Books::RecommendationCriteria.new({})

      def search_candidates(**args)
        @calls << [:search, args]
        raise "opensearch down" if @raise_search

        @candidates
      end

      def rank_ordered_candidates(**args)
        @calls << [:ranked, args]
        raise "opensearch down" if @raise_ranked

        @ranked
      end

      def item_facts(ids)
        ids.index_with { |id| @facts[id] || ItemFact.new(author_ids: [], genre_ids: [], series_predecessor_id: nil, rank_position: nil) }
      end

      def load_items(ids) = (ids - @missing_ids).index_with { |id| Item.new(id) }
    end

    # Available and returns a candidate, but its weight is zero: it must never reach fusion.
    class ZeroWeightSignal < Signals::Collaborative
      def available? = true

      def weight(_positive_count) = 0.0

      def call(profile:, interactions:, criteria:, excluded_ids:, size:)
        [Candidate.new(item_id: 104, score: 9.0, rank_position: 1, evidence: {})]
      end
    end

    RARE = 50

    def fact(id, type = "genre", count = 6)
      CategoryFact.new(id: id, category_type: type, item_count: count)
    end

    def setup
      @user = users(:regular_user)
      @interactions = (1..6).map { |i| Interaction.new(item_id: i, weight: 2.0, kind: :favorite, rating: nil) }
      @categories = (1..6).to_h { |i| [i, [fact(RARE)]] }.merge(101 => [fact(RARE)], 102 => [fact(RARE)], 103 => [fact(60)])
      @candidates = [101, 102, 103].map { |id| Candidate.new(item_id: id, score: 3.0 - id % 100 / 10.0, rank_position: id, evidence: {taste: true}) }
    end

    def engine(limit: 10, overrides: {}, **adapter_args)
      adapter = FakeAdapter.new(config: Config.resolve(overrides),
        interactions: @interactions, categories: @categories, candidates: @candidates, **adapter_args)
      [Engine.call(user: @user, domain: :books, limit: limit, overrides: overrides, adapter: adapter), adapter]
    end

    test "returns fused candidates in order with reasons and the profile" do
      result, = engine
      assert result.success?
      assert_equal [101, 102, 103], result.data[:items].map { |i| i[:item_id] }
      assert_equal [1, 2, 3], result.data[:items].map { |i| i[:rank] }
      assert_equal :interests, result.data[:items].first[:reason].type
      assert_equal [RARE], result.data[:items].first[:reason].ids
      assert_equal :ranked, result.data[:items].last[:reason].type
      assert_equal [:taste_profile], result.data[:signals_used]
      assert_not result.data[:fallback]
      assert_operator result.data[:profile].weight_for(RARE), :>, 0
      assert_kind_of Item, result.data[:items].first[:item]
    end

    test "respects the limit" do
      result, = engine(limit: 2)
      assert_equal 2, result.data[:items].size
    end

    test "passes the shelved ids as exclusions to the signal" do
      _, adapter = engine
      assert_equal (1..6).to_a, adapter.calls.find { |name, _| name == :search }.last[:excluded_ids]
    end

    test "falls back to rank-only when the profile is empty" do
      wanted = [Interaction.new(item_id: 1, weight: 0.2, kind: :want_to_read, rating: nil)]
      ranked = [Candidate.new(item_id: 7, score: 0.0, rank_position: 1, evidence: {})]
      result, adapter = engine(interactions: wanted, categories: {}, ranked: ranked)
      assert_equal [7], result.data[:items].map { |i| i[:item_id] }
      assert_equal Reason.new(type: :ranked, ids: [1]), result.data[:items].first[:reason]
      assert result.data[:fallback]
      assert_equal [], result.data[:signals_used]
      assert_nil adapter.calls.find { |name, _| name == :search }, "an empty profile sends no taste query"
    end

    test "a signal that raises is dropped, not fatal" do
      ranked = [Candidate.new(item_id: 7, score: 0.0, rank_position: 1, evidence: {})]
      result, = engine(raise_search: true, ranked: ranked)
      assert result.success?
      assert result.data[:fallback]
      assert_equal [7], result.data[:items].map { |i| i[:item_id] }
    end

    test "returns an empty success when every signal and the fallback fail" do
      result, = engine(raise_search: true, raise_ranked: true)
      assert result.success?
      assert_equal [], result.data[:items]
      assert_equal [], result.data[:signals_used]
    end

    test "applies the author cap and series rule" do
      facts = {101 => ItemFact.new(author_ids: [9], genre_ids: [], series_predecessor_id: nil, rank_position: 101),
               102 => ItemFact.new(author_ids: [9], genre_ids: [], series_predecessor_id: nil, rank_position: 102),
               103 => ItemFact.new(author_ids: [], genre_ids: [], series_predecessor_id: 999, rank_position: 103)}
      result, = engine(overrides: {max_per_author: 1}, facts: facts)
      assert_equal [101], result.data[:items].map { |i| i[:item_id] }
    end

    test "the series rule runs before the author cap, so a series opener survives" do
      # Fused order is book 3, book 2, book 1 by one author, and nothing is read.
      facts = {101 => ItemFact.new(author_ids: [9], genre_ids: [], series_predecessor_id: 102, rank_position: 101),
               102 => ItemFact.new(author_ids: [9], genre_ids: [], series_predecessor_id: 103, rank_position: 102),
               103 => ItemFact.new(author_ids: [9], genre_ids: [], series_predecessor_id: nil, rank_position: 103)}
      result, = engine(overrides: {max_per_author: 2}, facts: facts)
      assert_equal [103], result.data[:items].map { |i| i[:item_id] }
    end

    test "injected interactions and exclusions replace the adapter's (harness hold-out)" do
      held_out = Interaction.new(item_id: 101, weight: 2.0, kind: :favorite, rating: nil)
      adapter = FakeAdapter.new(config: Config.resolve, interactions: @interactions + [held_out],
        categories: @categories, candidates: @candidates)
      Engine.call(user: @user, domain: :books, limit: 10, adapter: adapter,
        interactions: @interactions, excluded_ids: (1..6).to_a)
      assert_equal (1..6).to_a, adapter.calls.find { |name, _| name == :search }.last[:excluded_ids]
    end

    test "a zero-weight signal never enters fusion" do
      adapter = FakeAdapter.new(config: Config.resolve, interactions: @interactions,
        categories: @categories, candidates: @candidates)
      result = Engine.call(user: @user, domain: :books, limit: 10, adapter: adapter,
        signal_classes: [Signals::TasteProfile, ZeroWeightSignal])
      assert_equal [101, 102, 103], result.data[:items].map { |i| i[:item_id] }
      assert_equal [:taste_profile], result.data[:signals_used]
    end

    test "ranks stay contiguous when the adapter cannot load an id" do
      result, = engine(missing_ids: [102])
      assert_equal [101, 103], result.data[:items].map { |i| i[:item_id] }
      assert_equal [1, 2], result.data[:items].map { |i| i[:rank] }
    end

    test "the result says it is degraded when a personalized signal raised, and not otherwise" do
      healthy, = engine
      assert_equal false, healthy.data[:degraded]

      ranked = [Candidate.new(item_id: 7, score: 0.0, rank_position: 1, evidence: {})]
      broken, = engine(raise_search: true, ranked: ranked)
      assert broken.success?
      assert broken.data[:degraded]
      assert broken.data[:fallback]
    end

    test "each item carries its global rank position" do
      # Positions deliberately differ from the ids, so returning the id fails.
      @candidates = [[101, 37], [102, 5], [103, 900]].map do |id, position|
        Candidate.new(item_id: id, score: 3.0 - id % 100 / 10.0, rank_position: position, evidence: {taste: true})
      end
      result, = engine
      assert_equal [101, 102, 103], result.data[:items].map { |i| i[:item_id] }
      assert_equal [37, 5, 900], result.data[:items].map { |i| i[:rank_position] }
    end

    test "an unregistered domain is a failure" do
      result = Engine.call(user: @user, domain: :music, limit: 10)
      assert_not result.success?
      assert_includes result.errors.first, "music"
    end
  end
end
