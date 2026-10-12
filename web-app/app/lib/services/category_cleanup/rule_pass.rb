# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.2 step 1: the decisions no AI is needed for. Every live books
    # location and subject gets a target name (or :delete, only for a broken
    # name fragment); categories whose target names are twins within a type
    # merge into the most-linked one. A category with no links is never deleted:
    # the sync brings categories over a day before their books, and legacy may
    # tag books with an empty category later.
    # Alternative names are deliberately not used: they come from legacy merge
    # history and include broader, narrower and reversed matches. Names the
    # rules can't improve get no decision and wait for the AI.
    #
    # `only_ids` (the post-sync step) limits which categories may receive a
    # decision; every live category still takes part in twin matching, and an
    # existing category wins over an incoming one.
    class RulePass
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      TYPES = %w[location subject].freeze

      def self.call(run:, only_ids: nil, stage: "rules")
        new(run: run, only_ids: only_ids, stage: stage).call
      end

      def initialize(run:, only_ids: nil, stage: "rules")
        @run = run
        @only_ids = only_ids&.to_set
        @stage = stage
      end

      def call
        decisions = []
        ::CategoryCleanupDecision.transaction do
          ::CategoryCleanupDecision.for_run(@run).where(stage: @stage, status: :proposed).delete_all
          decisions = build_decisions
          persist(decisions)
        end
        Result.new(success?: true, data: {decisions: decisions.size, by_action: decisions.map { |d| d[:action_name] }.tally}, errors: [])
      end

      private

      def build_decisions
        categories = load_categories
        counts = link_counts
        settled = ::CategoryCleanupDecision.for_run(@run).where.not(status: :proposed).distinct.pluck(:category_id).to_set
        targets = categories.to_h { |c| [c.id, NameNormalizer.target_name(c.name)] }

        decisions = categories.filter_map do |c|
          build(c, :delete, reason: "Broken name fragment") if targets[c.id] == :delete && writable?(c, settled)
        end

        live = categories.reject { |c| targets[c.id] == :delete }
        live.group_by { |c| [c.category_type, NameNormalizer.twin_key(targets[c.id]) || [:solo, c.id]] }.each_value do |members|
          winner = pick_winner(members, counts, targets)
          members.each do |c|
            next unless writable?(c, settled)

            if c.id != winner.id
              decisions << build(c, :merge, target_category_id: winner.id,
                reason: "Same name as #{winner.name.inspect} apart from case, punctuation or brackets")
            elsif targets[c.id] != c.name
              decisions << build(c, :rename, new_name: targets[c.id], reason: "Name clean-up")
            end
          end
        end
        decisions
      end

      def load_categories
        ::Books::Category.active
          .where(category_type: TYPES)
          .where.not(id: ::Books::Category.protected_ids)
          .select(:id, :name, :category_type, :alternative_names, :parent_id, :deleted, :item_count)
          .to_a
      end

      def link_counts
        ::CategoryItem.joins(:category)
          .where(categories: {type: "Books::Category", category_type: TYPES, deleted: false})
          .group(:category_id)
          .count
      end

      # Most links wins (preferring existing over incoming in a sync). If that
      # winner is about to be renamed and another member already holds exactly
      # the clean name, that member wins: it keeps its name and slug.
      def pick_winner(members, counts, targets)
        pool = @only_ids ? members.reject { |c| @only_ids.include?(c.id) } : []
        pool = members if pool.empty?
        winner = pool.max_by { |c| [counts[c.id].to_i, -c.id] }
        if targets[winner.id] != winner.name
          holder = pool.find { |c| c.id != winner.id && c.name == targets[winner.id] }
          return holder if holder
        end
        winner
      end

      def writable?(category, settled)
        !settled.include?(category.id) && (@only_ids.nil? || @only_ids.include?(category.id))
      end

      def build(category, action, new_name: nil, target_category_id: nil, reason: nil)
        {
          category_id: category.id,
          action: ::CategoryCleanupDecision.actions.fetch(action.to_s),
          action_name: action.to_s,
          new_name: new_name,
          target_category_id: target_category_id,
          reason: reason,
          category_snapshot: ::CategoryCleanupDecision.snapshot_of(category)
        }
      end

      def persist(decisions)
        now = Time.current
        common = {
          run: @run, stage: @stage, created_at: now, updated_at: now,
          decided_by: ::CategoryCleanupDecision.decided_bies.fetch("rule"),
          status: ::CategoryCleanupDecision.statuses.fetch("proposed")
        }
        decisions.each_slice(1000) do |slice|
          ::CategoryCleanupDecision.insert_all(slice.map { |d| d.except(:action_name).merge(common) })
        end
      end
    end
  end
end
