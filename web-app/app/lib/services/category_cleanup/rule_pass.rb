# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.2 step 1: the decisions no AI is needed for. Every live books
    # location and subject gets a target name (or :delete); categories whose
    # target names are twins within a type merge into the most-linked one; a
    # lone name that matches another category's alternative name merges into
    # it. Names the rules can't improve get no decision and wait for the AI.
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
        ::CategoryCleanupDecision.for_run(@run).where(stage: @stage, status: :proposed).delete_all
        categories = load_categories
        counts = link_counts
        settled = ::CategoryCleanupDecision.for_run(@run).where.not(status: :proposed).distinct.pluck(:category_id).to_set
        parents = ::Books::Category.active.where.not(parent_id: nil).distinct.pluck(:parent_id).to_set
        targets = categories.to_h { |c| [c.id, target_for(c, counts, parents)] }

        decisions = categories.filter_map do |c|
          build(c, :delete, reason: delete_reason(c, counts)) if targets[c.id] == :delete && writable?(c, settled)
        end

        live = categories.reject { |c| targets[c.id] == :delete }
        aliases = alias_index(live)
        live.group_by { |c| [c.category_type, NameNormalizer.twin_key(targets[c.id]) || [:solo, c.id]] }.each do |(type, key), members|
          winner = pick_winner(members, counts)
          members.each do |c|
            next unless writable?(c, settled)

            if c.id != winner.id
              decisions << build(c, :merge, target_category_id: winner.id,
                reason: "Same name as #{winner.name.inspect} apart from case, punctuation or brackets")
            elsif members.one? && (alias_target = aliases[[type, key]]) && alias_target != c.id
              decisions << build(c, :merge, target_category_id: alias_target, reason: "Matches another category's alternative name")
            elsif targets[c.id] != c.name
              decisions << build(c, :rename, new_name: targets[c.id], reason: "Name clean-up")
            end
          end
        end

        persist(decisions)
        Result.new(success?: true, data: {decisions: decisions.size, by_action: decisions.map { |d| d[:action_name] }.tally}, errors: [])
      end

      private

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

      # A category with places under it is never deleted, even with no links of
      # its own: it is a node of the location tree.
      def target_for(category, counts, parents)
        return :delete if counts[category.id].to_i.zero? && !parents.include?(category.id)

        NameNormalizer.target_name(category.name)
      end

      def delete_reason(category, counts)
        counts[category.id].to_i.zero? ? "No books" : "Broken name fragment"
      end

      def alias_index(categories)
        categories.each_with_object({}) do |c, index|
          c.alternative_names.each do |alt|
            key = NameNormalizer.twin_key(alt)
            index[[c.category_type, key]] ||= c.id if key
          end
        end
      end

      def pick_winner(members, counts)
        pool = @only_ids ? members.reject { |c| @only_ids.include?(c.id) } : []
        pool = members if pool.empty?
        pool.max_by { |c| [counts[c.id].to_i, -c.id] }
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
