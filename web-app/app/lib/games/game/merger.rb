module Games
  class Game
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      attr_reader :source_game, :target_game, :stats

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_game = source
        @target_game = target
        @source_game_id = source.id
        @stats = {}
        @affected_ranking_configurations = []
        @transaction_body_completed = false
      end

      def call
        if source_game.id == target_game.id
          return Result.new(
            success?: false,
            data: nil,
            errors: ["Cannot merge a game with itself"]
          )
        end

        ActiveRecord::Base.transaction do
          lock_games
          collect_affected_ranking_configurations
          merge_all_associations
          reconcile_scalars
          target_game.save! if target_game.changed?
          destroy_source_game
          @transaction_body_completed = true
        end

        run_post_commit_steps

        Result.new(success?: true, data: target_game, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        result_for_raised(error, error.message)
      rescue ActiveRecord::RecordNotUnique => error
        result_for_raised(error, "Constraint violation: #{error.message}")
      rescue => error
        result_for_raised(error, error.message)
      end

      private

      # Locks both rows FOR UPDATE before anything moves. Without it two admins
      # merging the same duplicate can both pass the guards above, and the loser's
      # destroy! silently affects zero rows -- games_games has no lock_version, so
      # Rails never checks the affected count -- reporting a completed merge that
      # moved nothing. Ascending id order stops two merges with swapped source and
      # target from deadlocking each other. Taking the lock here, before
      # reconcile_scalars dirties target_game, also keeps lock!'s
      # no-unsaved-changes requirement satisfied.
      def lock_games
        [source_game, target_game].sort_by(&:id).each(&:lock!)
      end

      # SearchIndexable's after_commit callbacks -- the target's save! and the
      # source's destroy! -- fire as the transaction block exits, which is AFTER the
      # commit, and Rails propagates anything they raise out of that block straight
      # into the rescues above, bypassing run_post_commit_steps entirely. Reporting
      # success?: false there would tell the admin a merge failed when the source is
      # already permanently deleted, and their retry would fail with "not found".
      #
      # Both halves of merge_committed? are load-bearing. The flag alone would
      # misread a COMMIT that itself failed as success; the missing row alone would
      # misread a merge that never started because a concurrent merge had already
      # consumed the source -- which is what lock_games raises on.
      def result_for_raised(error, message)
        return Result.new(success?: false, data: nil, errors: [message]) unless merge_committed?

        Rails.logger.error(
          "Games::Game::Merger: merge of #{@source_game_id} into #{target_game.id} " \
          "committed, but a commit callback failed: #{error.class}: #{error.message}"
        )
        @stats[:post_commit_error] = error.message
        Result.new(success?: true, data: target_game, errors: [])
      end

      def merge_committed?
        @transaction_body_completed && !::Games::Game.exists?(@source_game_id)
      end

      def merge_all_associations
        merge_identifiers
        merge_external_links
        merge_images
        merge_category_items
        merge_list_items
        merge_user_list_items
        merge_descriptions
        merge_game_companies
        merge_game_platforms
        merge_child_games
      end

      def merge_identifiers
        count = 0
        source_game.identifiers.find_each do |identifier|
          existing = target_game.identifiers.find_by(
            identifier_type: identifier.identifier_type,
            value: identifier.value
          )

          if existing
            identifier.destroy!
          else
            identifier.update!(identifiable_id: target_game.id)
            count += 1
          end
        end
        @stats[:identifiers] = count
      end

      def merge_external_links
        @stats[:external_links] = source_game.external_links.update_all(parent_id: target_game.id)
      end

      def merge_images
        has_target_primary = target_game.primary_image.present?
        count = 0

        source_game.images.find_each do |image|
          image.update!(
            parent_id: target_game.id,
            primary: has_target_primary ? false : image.primary
          )
          count += 1
        end

        @stats[:images] = count
      end

      def merge_category_items
        count = 0
        source_game.category_items.find_each do |category_item|
          target_game.category_items.find_or_create_by!(category_id: category_item.category_id)
          count += 1
        end
        @stats[:category_items] = count
      end

      def merge_list_items
        count = 0
        source_game.list_items.find_each do |list_item|
          # An auto-generated list's rows belong to the generator, which rewrites
          # them nightly from the underlying user favorites -- and this merge has
          # already moved those. Writing here would raise against the ListItem
          # guard and turn an admin merge into a 500.
          next if list_item.list.auto_generated?

          existing = target_game.list_items.find_by(list_id: list_item.list_id)

          if existing
            existing.update!(verified: true) if list_item.verified? && !existing.verified?
          else
            list_item.update!(listable_id: target_game.id)
          end
          count += 1
        end
        @stats[:list_items] = count
      end

      # position is scoped to the user_list, which does not change, so a moved row
      # keeps a valid position.
      def merge_user_list_items
        count = 0
        source_game.user_list_items.find_each do |entry|
          if UserListItem.exists?(user_list_id: entry.user_list_id, listable: target_game)
            entry.destroy!
          else
            entry.update!(listable_id: target_game.id)
            count += 1
          end
        end
        @stats[:user_list_items] = count
      end

      # Two unique indexes apply: one on
      # (describable, kind, locale, source, source_name) with nulls_not_distinct,
      # and a partial one allowing a single rank=1 row per (describable, kind, locale).
      def merge_descriptions
        preferred_keys = target_game.descriptions.select(&:preferred?)
          .map { |description| [description.kind, description.locale] }
          .to_set
        count = 0

        source_game.descriptions.find_each do |description|
          collides = target_game.descriptions.exists?(
            kind: description.kind,
            locale: description.locale,
            source: description.source,
            source_name: description.source_name
          )

          if collides
            description.destroy!
            next
          end

          attrs = {describable_id: target_game.id}
          if description.preferred? &&
              preferred_keys.include?([description.kind, description.locale])
            attrs[:rank] = :normal
          end

          description.update!(attrs)
          count += 1
        end
        @stats[:descriptions] = count
      end

      # developer/publisher are ORed rather than dropped: a source row marking a
      # company as publisher carries information the target's row may not have.
      def merge_game_companies
        count = 0
        source_game.game_companies.find_each do |link|
          existing = target_game.game_companies.find_by(company_id: link.company_id)

          if existing
            existing.update!(
              developer: existing.developer? || link.developer?,
              publisher: existing.publisher? || link.publisher?
            )
            link.destroy!
          else
            link.update!(game_id: target_game.id)
            count += 1
          end
        end
        @stats[:game_companies] = count
      end

      def merge_game_platforms
        count = 0
        source_game.game_platforms.find_each do |link|
          if target_game.game_platforms.exists?(platform_id: link.platform_id)
            link.destroy!
          else
            link.update!(game_id: target_game.id)
            count += 1
          end
        end
        @stats[:game_platforms] = count
      end

      # child_games is dependent: :nullify, so leaving these alone orphans the whole
      # subtree when the source is destroyed. The target itself cannot become its own
      # parent, so it is nullified instead. This also covers a target that is a
      # *deeper* descendant of the source (source -> C -> target): target's ancestry
      # runs through the source, which is about to be destroyed, so it is meaningless
      # after the merge either way. Breaking that edge is what prevents a cycle when
      # the source's direct children (including C) are repointed to the target below.
      def merge_child_games
        target_was_descendant = descendant_of?(target_game.id, source_game.id)
        if target_was_descendant
          ::Games::Game.where(id: target_game.id).update_all(parent_game_id: nil)
        end

        # By this point target_game's own parent_game_id (if it ran through the
        # source at all) has already been nilled above, so it can never match
        # parent_game_id: source_game.id here and be repointed to itself.
        count = ::Games::Game.where(parent_game_id: source_game.id)
          .update_all(parent_game_id: target_game.id)

        # Safe to discard target_game's in-memory state here ONLY because:
        # (1) merge_child_games runs last in merge_all_associations, so no earlier
        #     association method has left an unsaved change on target_game;
        # (2) reconcile_scalars, which does dirty target_game, runs after
        #     merge_all_associations, not before. Moving this call earlier, or
        #     adding a scalar fill inside any merge_* method, would make this
        #     reload silently discard that change.
        target_game.reload if target_was_descendant
        @stats[:child_games] = count
      end

      # Games have no alternate_titles column, so there is no name absorption here.
      # Books and authors (increments 2 and 3) do.
      # When descriptions-subsystem step (e) drops games_games.description (see
      # docs/superpowers/specs/2026-07-27-descriptions-subsystem-design.md), remove
      # :description from this list or fill_blank_fields raises inside the transaction.
      BLANK_FILLABLE = %i[description series_id].freeze

      def reconcile_scalars
        fill_blank_fields
        merge_release_year
        fill_parent_game
      end

      def fill_blank_fields
        filled = []

        BLANK_FILLABLE.each do |field|
          next if target_game.public_send(field).present?

          value = source_game.public_send(field)
          next if value.blank?

          target_game.public_send(:"#{field}=", value)
          filled << field
        end

        @stats[:filled_fields] = filled
      end

      def merge_release_year
        return if source_game.release_year.blank?

        if target_game.release_year.nil? || source_game.release_year < target_game.release_year
          target_game.release_year = source_game.release_year
          @stats[:release_year_updated] = true
        end
      end

      # Only fills a genuinely blank parent, and only when doing so is legal:
      # parent_game_valid_for_type rejects a parent on a main game, and a parent that
      # is the target itself (or a descendant of it) would be a cycle.
      def fill_parent_game
        return if target_game.parent_game_id.present?
        return if target_game.main_game?

        candidate_id = source_game.parent_game_id
        return if candidate_id.blank?
        return if candidate_id == target_game.id
        return if descendant_of_target?(candidate_id)

        target_game.parent_game_id = candidate_id
      end

      def descendant_of_target?(game_id)
        descendant_of?(game_id, target_game.id)
      end

      # Walks up parent_game_id from game_id looking for ancestor_id. The Set guard
      # is load-bearing: it terminates the walk even against data that is already
      # cyclic, rather than looping forever.
      def descendant_of?(game_id, ancestor_id)
        seen = Set.new
        current = game_id

        while current.present? && seen.add?(current)
          return true if current == ancestor_id
          current = ::Games::Game.where(id: current).pick(:parent_game_id)
        end

        false
      end

      # The merge is committed by this point. Reindexing and ranking recalculation
      # are follow-up work: if they fail, the merge still happened, so a failure
      # here must not be reported as a failed merge. `success?` means "the merge
      # committed", and that is what the admin UI reports.
      def run_post_commit_steps
        reindex_target_game
        schedule_ranking_recalculation
        regenerate_user_favorites_list
      rescue => error
        Rails.logger.error(
          "Games::Game::Merger: merge of #{source_game.id} into #{target_game.id} " \
          "committed, but post-commit follow-up failed: #{error.class}: #{error.message}"
        )
        @stats[:post_commit_error] = error.message
      end

      def collect_affected_ranking_configurations
        source_configs = RankedItem.where(item_type: "Games::Game", item_id: source_game.id)
          .pluck(:ranking_configuration_id)
        target_configs = RankedItem.where(item_type: "Games::Game", item_id: target_game.id)
          .pluck(:ranking_configuration_id)

        @affected_ranking_configurations = (source_configs + target_configs).uniq
      end

      # SearchIndexable already respects this flag on its own callbacks; the merger
      # matches it rather than writing requests during a bulk migration.
      def reindex_target_game
        return if Services::BooksMigration.search_indexing_suppressed?

        SearchIndexRequest.create!(parent: target_game, action: :index_item)
      end

      def schedule_ranking_recalculation
        @affected_ranking_configurations.each do |config_id|
          BulkCalculateWeightsJob.perform_async(config_id)
          CalculateRankingsJob.perform_in(5.minutes, config_id)
        end
      end

      # The generated "Our Users' Favorites" list is derived data: merge_list_items
      # above deliberately skips (rather than repoints) a source row that sits on
      # that list, so the row is destroyed along with the source game and the
      # generated list falls one item short. Only a full rebuild -- not a repointed
      # row -- produces the correct combined score, voter_count and position for
      # the target game, so the list is regenerated here rather than waiting for
      # the nightly cron. Queuing it now runs it comfortably inside the 5 minutes
      # before schedule_ranking_recalculation's CalculateRankingsJob would otherwise
      # read that short list and bake the wrong result into the rankings.
      def regenerate_user_favorites_list
        GenerateUserFavoritesListsJob.perform_async("Games::UserList")
      end

      def destroy_source_game
        source_game.destroy!
      end
    end
  end
end
