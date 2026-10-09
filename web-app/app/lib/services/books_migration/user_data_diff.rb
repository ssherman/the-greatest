module Services
  module BooksMigration
    # The user-data half of data_migration:sync_report (spec §7): per table, what
    # the next sync would insert, update, delete and drop. Read-only.
    #
    # Insert and delete compare ids. Update compares updated_at: these migrators
    # keep legacy's timestamps, so a newer legacy row has changed. It is a report
    # number only, because the sync overwrites every legacy-origin row anyway. List
    # items compare a digest per list on both sides, and only the lists that differ
    # go through UserListItemPlan, the same plan the sync applies. Reviews and
    # corrections route and dedupe exactly as their migrators do.
    class UserDataDiff
      LIST_BATCH = 1_000

      def self.call(scope:, legacy: LegacySource.new)
        new(scope: scope, legacy: legacy).call
      end

      def initialize(scope:, legacy:)
        @legacy = legacy
        # The run's own new books count as here: the user-data steps run after them.
        @route = BookRoute.new(scope, book_ids_here: ::Books::Book.pluck(:id).to_set | scope.book_ids)
      end

      def call
        list_versions = @legacy.user_list_versions
        {
          users: users,
          user_lists: versioned(list_versions, ::Books::UserList, "user_lists"),
          user_list_items: user_list_items(list_versions.keys),
          reviews: reviews,
          saved_searches: versioned(@legacy.saved_search_versions, ::Books::SavedSearch, "saved_searches"),
          reading_goals: reading_goals,
          recommendation_configs: {legacy: @legacy.recommendation_config_count, here: ::Books::RecommendationConfig.count},
          corrections: corrections
        }
      end

      private

      def ceiling(table) = RESERVED_CEILINGS.fetch(table)

      # Users are never deleted (spec §6), so a legacy deletion is only counted.
      def users
        counts = versioned(@legacy.user_versions, ::User, "users")
        counts.merge(deleted_on_legacy: counts.delete(:deleted))
      end

      def versioned(legacy_versions, model, table)
        here = model.where(id: ...ceiling(table)).pluck(:id, :updated_at).to_h
        {
          legacy: legacy_versions.size,
          here: here.size,
          inserted: legacy_versions.keys.count { |id| !here.key?(id) },
          updated: legacy_versions.count { |id, updated_at| here.key?(id) && updated_at > here[id] },
          deleted: here.keys.count { |id| !legacy_versions.key?(id) }
        }
      end

      def user_list_items(legacy_list_ids)
        legacy_digests = @legacy.user_list_item_digests
        here_digests = here_item_digests
        counts = {
          legacy: legacy_digests.values.sum(&:first), here: here_digests.values.sum(&:first),
          inserted: 0, deleted: 0, dropped: 0, waiting: 0, collisions: 0, missing: 0
        }
        changed = legacy_list_ids.reject { |id| legacy_digests[id] == here_digests[id] }
        changed.each_slice(LIST_BATCH) do |list_ids|
          here = ::UserListItem.where(user_list_id: list_ids).pluck(:id, :user_list_id, :listable_type, :listable_id)
          plan = UserListItemPlan.call(@legacy.user_list_items_for(list_ids), here, @route)
          counts[:inserted] += plan.inserted
          counts[:deleted] += plan.stale_ids.size
          counts[:missing] += plan.missing.size
          %i[dropped waiting collisions].each { |key| counts[key] += plan.public_send(key) }
        end
        counts
      end

      def here_item_digests
        ::UserListItem.joins(:user_list)
          .where(user_lists: {type: "Books::UserList", id: ...ceiling("user_lists")})
          .group(:user_list_id)
          .pluck(
            :user_list_id, Arel.sql("COUNT(*)"),
            Arel.sql("md5(string_agg(user_list_items.listable_id::text, ',' ORDER BY user_list_items.listable_id))")
          )
          .to_h { |list_id, count, digest| [list_id, [count, digest]] }
      end

      # Mirrors ReviewMigrator: newest first, the first row per user and routed
      # book wins, and a key a new-app review holds stays the new-app review's.
      def reviews
        counts = {dropped: 0, waiting: 0, collisions: 0, held_by_new_app: 0, missing: 0}
        new_app_keys = ::Review.where(reviewable_type: "Books::Book", id: ceiling("reviews")..)
          .pluck(:user_id, :reviewable_id).to_set
        seen = Set.new
        kept = {}
        rows = @legacy.review_rows
        rows.each do |id, user_id, book_id, updated_at|
          routed = @route.call(book_id)
          if routed.is_a?(Symbol)
            counts[(routed == :deleted) ? :dropped : routed] += 1
          elsif !seen.add?([user_id, routed])
            counts[:collisions] += 1
          elsif new_app_keys.include?([user_id, routed])
            counts[:held_by_new_app] += 1
          else
            kept[id] = updated_at
          end
        end

        here = ::Review.where(reviewable_type: "Books::Book", id: ...ceiling("reviews")).pluck(:id, :updated_at).to_h
        counts.merge(
          legacy: rows.size,
          here: here.size,
          inserted: kept.keys.count { |id| !here.key?(id) },
          updated: kept.count { |id, updated_at| here.key?(id) && updated_at > here[id] },
          deleted: here.keys.count { |id| !kept.key?(id) }
        )
      end

      def reading_goals
        legacy_ids = @legacy.reading_goal_ids.to_set
        here = ::Books::ReadingGoal.where(id: ...ReadingGoalMigrator::RESERVED_ID_FLOOR).pluck(:id)
        {legacy: legacy_ids.size, here: here.size, deleted: here.count { |id| !legacy_ids.include?(id) }}
      end

      # Mirrors CorrectionMigrator: insert-only, so only ids not here count, while
      # dropped, waiting and missing count every legacy row on such a book.
      def corrections
        rows = @legacy.correction_rows
        here = ::Correction.where(id: ...ceiling("corrections")).pluck(:id).to_set
        counts = {legacy: rows.size, here: here.size, inserted: 0, dropped: 0, waiting: 0, missing: 0}
        rows.each do |id, book_id|
          routed = @route.call(book_id)
          if routed.is_a?(Integer)
            counts[:inserted] += 1 unless here.include?(id)
          else
            counts[(routed == :deleted) ? :dropped : routed] += 1
          end
        end
        counts
      end
    end
  end
end
