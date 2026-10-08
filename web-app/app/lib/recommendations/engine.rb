# frozen_string_literal: true

module Recommendations
  # The pipeline (spec §5): interactions -> profile -> signals -> fusion ->
  # re-ranking -> explanations. Domain-agnostic: every domain fact comes through
  # the adapter the registry resolves. A signal that raises is logged and
  # dropped; if nothing is left, the rank-only fallback fills the page; if that
  # fails too, the result is an empty success (the page shows "unavailable",
  # never a 500).
  class Engine
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    PERSONALIZED_SIGNALS = [Signals::TasteProfile, Signals::Collaborative].freeze

    def self.call(**args)
      new(**args).call
    end

    def initialize(user:, domain:, limit:, overrides: {}, adapter: nil, interactions: nil, excluded_ids: nil, signal_classes: PERSONALIZED_SIGNALS)
      @user = user
      @domain = domain
      @limit = limit.to_i
      @config = Config.resolve(overrides)
      @adapter = adapter
      @interactions_override = interactions
      @excluded_override = excluded_ids
      @signal_classes = signal_classes
    end

    def call
      adapter = resolve_adapter
      return Result.new(success?: false, data: nil, errors: ["no recommendation adapter for domain #{@domain}"]) if adapter.nil?

      interactions = @interactions_override || adapter.interactions(@user)
      excluded_ids = @excluded_override || adapter.shelved_item_ids(@user)
      criteria = adapter.criteria_for(@user)
      profile = build_profile(adapter, interactions)
      size = @config[:candidate_size]

      lists, signals_used = run_signals(adapter, profile, interactions, criteria, excluded_ids, size)
      fallback = lists.empty?
      fused = if fallback
        run_fallback(adapter, profile, interactions, criteria, excluded_ids, size)
      else
        Fusion.call(lists: lists, config: @config)
      end

      page = rerank(adapter, fused, interactions, profile)
      Result.new(success?: true, errors: [], data: {
        items: build_items(adapter, page, profile),
        profile: profile,
        signals_used: signals_used,
        fallback: fallback
      })
    end

    private

    def resolve_adapter
      return @adapter if @adapter

      klass = Registry.adapter_class_for(@domain)
      klass&.new(config: @config)
    end

    def build_profile(adapter, interactions)
      ProfileBuilder.call(
        interactions: interactions,
        categories: adapter.categories_for(interactions.map(&:item_id)),
        catalog_size: adapter.catalog_size,
        type_category_ids: adapter.type_category_ids,
        config: @config
      )
    end

    def run_signals(adapter, profile, interactions, criteria, excluded_ids, size)
      positive_count = profile.counts[:positive].to_i
      lists = []
      used = []
      @signal_classes.each do |klass|
        signal = klass.new(adapter: adapter, config: @config)
        next unless signal.available?

        # A zero-weight list is skipped before it is ever called: the rank prior
        # inside Fusion would otherwise surface its items anyway.
        weight = signal.weight(positive_count)
        next unless weight.positive?

        candidates = guarded(signal.name) do
          signal.call(profile: profile, interactions: interactions, criteria: criteria, excluded_ids: excluded_ids, size: size)
        end
        next if candidates.blank?

        lists << {weight: weight, candidates: candidates}
        used << signal.name
      end
      [lists, used]
    end

    def run_fallback(adapter, profile, interactions, criteria, excluded_ids, size)
      signal = Signals::RankOnly.new(adapter: adapter, config: @config)
      guarded(signal.name) do
        signal.call(profile: profile, interactions: interactions, criteria: criteria, excluded_ids: excluded_ids, size: size)
      end || []
    end

    def rerank(adapter, fused, interactions, profile)
      return [] if fused.empty?

      facts = adapter.item_facts(fused.map(&:item_id))
      # Series rule first: the cap must not spend an author's slots on sequels
      # the series rule then drops, which would lose the series opener too.
      page = Reranker::SeriesRule.call(fused, facts: facts, interactions: interactions)
      page = Reranker::AuthorCap.call(page, facts: facts, config: @config)
      Reranker::GenreCalibration.call(page, facts: facts, history: profile.genre_distribution, limit: @limit, config: @config)
    end

    def build_items(adapter, page, profile)
      return [] if page.empty?

      ids = page.map(&:item_id)
      items = adapter.load_items(ids)
      categories = adapter.categories_for(ids)
      loaded = page.filter_map do |candidate|
        item = items[candidate.item_id]
        next if item.nil?

        {
          item: item,
          item_id: candidate.item_id,
          score: candidate.score,
          reason: Explainer.call(candidate: candidate, profile: profile, categories: categories.fetch(candidate.item_id, []), config: @config)
        }
      end
      # Number after dropping ids the adapter could not load, so rank is the
      # 1-based position on the page with no gaps.
      loaded.each.with_index(1) { |entry, rank| entry[:rank] = rank }
    end

    # Class and a short backtrace, as SimilarBooks logs, so a genuine bug in a
    # signal is distinguishable from an OpenSearch outage.
    def guarded(signal_name)
      yield
    rescue => e
      Rails.logger.error "Recommendations signal #{signal_name} failed for user #{@user&.id}: #{e.class}: #{e.message} #{e.backtrace&.first(5)&.join(" | ")}"
      nil
    end
  end
end
