# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.3: executes a run's proposed decisions in dependency order --
    # rename, merge, retype, create missing parents, set parent, delete -- then
    # reconciles inherited links once. Staleness is checked for every decision
    # before anything is applied. Each decision is its own savepoint: a failure
    # marks that decision `failed` and the run carries on. Re-running only
    # touches decisions still `proposed`, so it is idempotent.
    class Applier
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      COMPARED = %w[name category_type parent_id deleted].freeze

      def self.call(run:, only_rules: false)
        new(run: run, only_rules: only_rules).call
      end

      def initialize(run:, only_rules: false)
        @run = run
        @only_rules = only_rules
        @stats = Hash.new(0)
      end

      def call
        mark_stale
        %w[rename merge retype].each { |action| apply_each(action) }
        @lookup = LocationLookup.new
        create_missing_parents
        apply_each("set_parent")
        apply_each("delete")
        kept = pending.where(action: :keep).update_all(status: ::CategoryCleanupDecision.statuses.fetch("applied"), updated_at: Time.current)
        @stats["keep"] += kept if kept.positive?

        changed = @stats.except("keep", "stale", "failed").values.sum
        ::Categories::AncestorReconciler.call if changed.positive?
        Result.new(success?: true, data: @stats.to_h, errors: [])
      end

      private

      def pending
        scope = ::CategoryCleanupDecision.for_run(@run).proposed
        @only_rules ? scope.decided_by_rule : scope
      end

      def mark_stale
        applied = ::CategoryCleanupDecision.for_run(@run).applied.order(:id).to_a.group_by(&:category_id)
        pending.includes(:category).find_each do |decision|
          next if unchanged?(decision, applied.fetch(decision.category_id, []))

          decision.update_columns(status: ::CategoryCleanupDecision.statuses.fetch("stale"),
            error: "Category changed after this decision was proposed", updated_at: Time.current)
          @stats["stale"] += 1
        end
      end

      # The snapshot, adjusted for decisions of this run that already landed
      # (a re-run after a crash between phases must not call those stale).
      def unchanged?(decision, applied)
        category = decision.category
        expected = decision.category_snapshot.slice(*COMPARED)
        applied.each do |done|
          expected["name"] = done.new_name if done.action_rename?
          expected["parent_id"] = category.parent_id if done.action_set_parent?
          expected["category_type"] = ::Category.category_types.key(done.new_category_type) if done.action_retype?
        end
        current = {"name" => category.name, "category_type" => category.category_type, "parent_id" => category.parent_id, "deleted" => category.deleted}
        current == expected
      end

      def apply_each(action)
        pending.where(action: action).find_each { |decision| apply_one(decision) }
      end

      def apply_one(decision)
        ::Category.transaction(requires_new: true) do
          send(:"apply_#{decision.action}", decision)
          decision.update!(status: :applied, error: nil)
        end
        @stats[decision.action] += 1
      rescue => e
        decision.update_columns(status: ::CategoryCleanupDecision.statuses.fetch("failed"), error: e.message.truncate(500), updated_at: Time.current)
        @stats["failed"] += 1
      end

      def apply_rename(decision)
        live_category!(decision).update!(name: decision.new_name)
      end

      def apply_merge(decision)
        target = decision.target_category&.canonical
        raise "merge target is gone" if target.nil?

        ::Categories::Merger.new(category: live_category!(decision), category_to_merge_with: target).merge
      end

      def apply_retype(decision)
        category = live_category!(decision)
        raise "#{category.name} has places under it" if category.child_categories.active.exists?

        category.update!(category_type: ::Category.category_types.key(decision.new_category_type), parent_id: nil)
      end

      def apply_set_parent(decision)
        category = live_category!(decision)
        parent_id = @lookup.find(decision.parent_chain.first)
        raise "parent #{decision.parent_chain.first.inspect} not found" if parent_id.nil?
        raise "a place can't be its own parent" if parent_id == category.id

        category.update!(parent_id: parent_id)
      end

      def apply_delete(decision)
        category = live_category!(decision)
        raise "#{category.name} has places under it" if category.child_categories.active.exists?

        ::Categories::Deleter.new(category: category, soft: true).delete
      end

      def live_category!(decision)
        category = ::Books::Category.find_by(id: decision.category_id)
        raise "category is gone" if category.nil? || category.deleted?
        raise "#{category.name} is a protected book-type category" if ::Books::Category.protected_ids.include?(category.id)

        category
      end

      # Chain names that match no live location become new locations. Each
      # takes its parent from the next name in the first chain (by decision id)
      # that mentions it, and gets an applied `keep` so later syncs see it as
      # decided.
      def create_missing_parents
        wanted = {}
        pending.action_set_parent.order(:id).each do |decision|
          decision.parent_chain.each_with_index do |name, index|
            key = NameNormalizer.twin_key(name)
            next if key.nil? || @lookup.find(name) || wanted.key?(key)

            wanted[key] = [name, decision.parent_chain[index + 1]]
          end
        end

        created = wanted.values.map do |name, parent_name|
          category = ::Books::Category.create!(name: name, category_type: :location)
          @lookup.register(category)
          record_created(category)
          @stats["created"] += 1
          [category, parent_name]
        end

        created.each do |category, parent_name|
          parent_id = @lookup.find(parent_name)
          category.update!(parent_id: parent_id) if parent_id && parent_id != category.id
        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.warn("[category cleanup] #{category.name}: parent #{parent_name.inspect} refused (#{e.message}); left as a root")
        end
      end

      def record_created(category)
        ::CategoryCleanupDecision.create!(
          category: category, run: @run, stage: "apply", action: :keep, decided_by: :rule, status: :applied,
          reason: "Created as a parent in the location hierarchy",
          category_snapshot: ::CategoryCleanupDecision.snapshot_of(category)
        )
      end
    end
  end
end
