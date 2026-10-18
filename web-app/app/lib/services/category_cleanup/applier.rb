# frozen_string_literal: true

module Services
  module CategoryCleanup
    # Spec §4.3: executes a run's proposed decisions in dependency order --
    # rename, merge, split, retype, create missing parents, set parent, delete,
    # keep (with extra targets) -- then
    # reconciles inherited links once. Staleness is checked for every decision
    # before anything is applied. Each decision is its own savepoint: a failure
    # marks that decision `failed` and the run carries on. Re-running only
    # touches decisions still `proposed`, so it is idempotent.
    class Applier
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      COMPARED = %w[name category_type parent_id deleted].freeze
      STAT_KEYS = %w[rename merge split retype set_parent delete keep created stale failed].freeze
      # Which terminal decision wins when one category has several: phase order.
      TERMINAL_RANK = {"merge" => 0, "split" => 1, "retype" => 2, "delete" => 3}.freeze

      def self.call(run:, only_rules: false)
        new(run: run, only_rules: only_rules).call
      end

      def initialize(run:, only_rules: false)
        @run = run
        @only_rules = only_rules
        @stats = Hash.new(0).merge(STAT_KEYS.index_with(0))
      end

      def call
        mark_stale
        %w[rename merge split retype].each { |action| apply_each(action) }
        @lookup = LocationLookup.new
        create_missing_parents
        apply_each("set_parent")
        apply_each("delete")
        # A keep with extra targets (genre cleanup `also:`) links books, so it
        # runs one by one; a plain keep only records the decision.
        pending.where(action: :keep).where.not(extra_target_ids: []).find_each { |decision| apply_one(decision) }
        kept = pending.where(action: :keep).update_all(status: ::CategoryCleanupDecision.statuses.fetch("applied"), updated_at: Time.current)
        @stats["keep"] += kept if kept.positive?

        # Idempotent, and run whenever the run has applied anything: a crash or
        # failure inside it on an earlier invocation must not be skipped on re-run.
        ::Categories::AncestorReconciler.call if ::CategoryCleanupDecision.for_run(@run).applied.exists?
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
        break_merge_cycles
        supersede_conflicting
      end

      # Head categories are decided one per call, so the AI can merge A into B
      # in one answer and B into A in another. In id order the first merge
      # lands into whichever name came first and the reverse fails as a merge
      # into itself. Instead, each cycle is broken at its most-linked member
      # (item_count, as in the rules pass): that member's merge goes stale, so
      # it stays, with any rename, and the rest of the cycle merges into it.
      # A member that also has a proposed retype or delete is never the root:
      # with its merge gone that decision would win the supersede pass, and a
      # delete would then remove every link the cycle merged into it. If every
      # member has one, the cycle is left alone: one merge lands, the reverse
      # fails, and nothing is lost.
      def break_merge_cycles
        merges = pending.where(action: :merge).order(:id).to_a.uniq(&:category_id).index_by(&:category_id)
        return if merges.empty?

        targets = merges.values.map(&:target_category_id)
        forwarded = ::Category.where(id: targets).where.not(merged_into_id: nil).pluck(:id, :merged_into_id).to_h
        target_of = merges.transform_values { |merge| forwarded.fetch(merge.target_category_id, merge.target_category_id) }
        visited = Set.new
        merges.each_key do |start|
          path = []
          node = start
          while node && !visited.include?(node) && !path.include?(node)
            path << node
            node = target_of[node]
          end
          visited.merge(path)
          next unless node && path.include?(node)

          cycle = path[path.index(node)..]
          blocked = pending.where(action: [:retype, :delete], category_id: cycle).distinct.pluck(:category_id)
          candidates = cycle - blocked
          next if candidates.empty?

          counts = ::Category.where(id: candidates).pluck(:id, :item_count).to_h
          root = candidates.max_by { |id| [counts.fetch(id, 0), -id] }
          merges[root].update_columns(status: ::CategoryCleanupDecision.statuses.fetch("stale"),
            error: "merge cycle: this category has the most links of #{cycle.size}, so the others merge into it", updated_at: Time.current)
          @stats["stale"] += 1
        end
      end

      # A category with a proposed merge, retype or delete cannot also be
      # renamed, re-parented or kept: the terminal decision wins and the rest go
      # stale. With several terminal decisions the first by phase order (merge,
      # retype, delete; ties by id) is kept. The one exception: a RENAME that
      # accompanies a winning retype survives (the rename phase runs first, so
      # "not a place -> subject, under a cleaner name" applies as a pair).
      def supersede_conflicting
        pending.order(:id).to_a.group_by(&:category_id).each_value do |decisions|
          winner = decisions.select { |d| TERMINAL_RANK.key?(d.action) }.min_by { |d| [TERMINAL_RANK[d.action], d.id] }
          next if winner.nil?

          losers = decisions - [winner]
          losers = losers.reject(&:action_rename?) if winner.action_retype?
          losers.each do |loser|
            loser.update_columns(status: ::CategoryCleanupDecision.statuses.fetch("stale"),
              error: "superseded by #{winner.action} decision ##{winner.id}", updated_at: Time.current)
            @stats["stale"] += 1
          end
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
        decision.update_columns(status: ::CategoryCleanupDecision.statuses.fetch("failed"), error: "#{e.class}: #{e.message}".truncate(500), updated_at: Time.current)
        @stats["failed"] += 1
      end

      def apply_rename(decision)
        category = live_category!(decision)
        rename_category(category, decision.new_name)
        link_books(category, decision.extra_target_ids)
      end

      def rename_category(category, new_name)
        old_name = category.name
        old_key = NameNormalizer.twin_key(old_name)
        alternatives = Array(category.alternative_names)
        remember_old = old_key && old_key != NameNormalizer.twin_key(new_name) &&
          alternatives.none? { |alt| NameNormalizer.twin_key(alt) == old_key }
        # Keep the old name as an alternative so a set_parent chain proposed
        # against it still resolves once the rename has landed.
        category.update!({name: new_name}.merge(remember_old ? {alternative_names: alternatives + [old_name]} : {}))
      end

      def apply_keep(decision)
        link_books(live_category!(decision), decision.extra_target_ids)
      end

      # Spec 2026-10-17 section 4, "Combined genres". Each book gets the targets
      # split_check assigned it (all of them when it has no answer), then the
      # genre's own book links go: merging mode merges the emptied genre into
      # the primary, so saved searches, old URLs and legacy links follow it;
      # renaming mode keeps the links of books assigned the primary and renames.
      def apply_split(decision)
        category = live_category!(decision)
        raise "#{category.name} has places under it" if category.child_categories.active.exists?

        primary_id = decision.target_category_id ? decision.target_category.canonical.id : category.id
        targets = ([primary_id] + decision.extra_target_ids).uniq
        links = category.category_items.where(item_type: "Books::Book").pluck(:item_id, :source).to_h
        assigned = decision.split_assignments.transform_keys(&:to_i)
        wanted = links.keys.index_with { |book_id| Array(assigned.fetch(book_id, targets)).map(&:to_i) & targets }

        insert_links(wanted.flat_map { |book_id, ids| (ids - [category.id]).map { |id| [id, book_id, links[book_id]] } })
        if decision.target_category_id
          ::CategoryItem.where(category_id: category.id, item_type: "Books::Book").delete_all
          ::Categories::Merger.new(category: category, category_to_merge_with: ::Category.find(primary_id)).merge
        else
          dropped = wanted.reject { |_book_id, ids| ids.include?(category.id) }.keys
          ::CategoryItem.where(category_id: category.id, item_type: "Books::Book", item_id: dropped).delete_all
          rename_category(category, decision.new_name)
        end
        ::Categories::ItemCounter.call(([category.id] + targets).uniq)
        ::Categories::ItemReindexer.queue_items(links.keys.map { |book_id| ["Books::Book", book_id] })
      end

      # Links every book of `category` to each of `target_ids`, keeping each
      # link's origin; existing links are left alone.
      def link_books(category, target_ids)
        return if target_ids.blank?

        links = category.category_items.where(item_type: "Books::Book").pluck(:item_id, :source)
        insert_links(target_ids.flat_map { |id| links.map { |book_id, origin| [id, book_id, origin] } })
        ::Categories::ItemCounter.call(target_ids)
        ::Categories::ItemReindexer.queue_items(links.map { |book_id, _| ["Books::Book", book_id] })
      end

      # rows: [[category_id, book_id, origin], ...]
      def insert_links(rows)
        return if rows.empty?

        now = Time.current
        ::CategoryItem.insert_all(
          # pluck returns the enum's name; insert_all skips enum casting.
          rows.map { |category_id, book_id, origin| {category_id: category_id, item_type: "Books::Book", item_id: book_id, source: ::CategoryItem.sources.fetch(origin.to_s), created_at: now, updated_at: now} },
          unique_by: :index_category_items_on_category_id_and_item_type_and_item_id
        )
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
        raise "#{category.name} is not a location" unless category.location?

        # A chain name can resolve to the place itself: the AI names a city's
        # administrative twin as its parent ("Berlin (state)") and, in its own
        # decision, merges that twin into the city. Skip it for the next name.
        parent_id = nil
        decision.parent_chain.each do |name|
          id = @lookup.find(name)
          raise "parent #{name.inspect} not found" if id.nil?
          next if id == category.id

          parent_id = id
          break
        end
        raise "a place can't be its own parent" if parent_id.nil?

        category.update!(parent_id: parent_id)
      end

      def apply_delete(decision)
        category = live_category!(decision)
        raise "#{category.name} has places under it" if category.child_categories.active.exists?

        ::Categories::Deleter.new(category: category, soft: true).delete
      end

      def live_category!(decision)
        category = ::Category.find_by(id: decision.category_id)
        raise "category is gone" if category.nil?
        raise "category is not a books category" unless category.is_a?(::Books::Category)
        raise "category is gone" if category.deleted?
        raise "#{category.name} is a protected book-type category" if ::Books::Category.protected_ids.include?(category.id)

        category
      end

      # Chain names that match no live location become new locations. Each
      # takes its parent from the next name in the first chain (by decision id)
      # that mentions it, and gets an applied `keep` so later syncs see it as
      # decided.
      def create_missing_parents
        wanted = {}
        protected_ids = ::Books::Category.protected_ids
        pending.action_set_parent.includes(:category).order(:id).each do |decision|
          category = decision.category
          next unless category.is_a?(::Books::Category) && category.location? && !category.deleted? && !protected_ids.include?(category.id)

          decision.parent_chain.each_with_index do |name, index|
            key = NameNormalizer.twin_key(name)
            next if key.nil? || @lookup.find(name) || wanted.key?(key)

            wanted[key] = [name, decision.parent_chain[index + 1]]
          end
        end

        # One transaction: a crash between creating the places and parenting
        # them must not leave permanent roots.
        ::Category.transaction do
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
