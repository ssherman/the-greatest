module Music
  class Album
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      attr_reader :source_album, :target_album, :stats

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_album = source
        @target_album = target
        @source_album_id = source.id
        @stats = {}
        @affected_ranking_configurations = []
        @transaction_body_completed = false
      end

      def call
        if source_album.id == target_album.id
          return Result.new(
            success?: false,
            data: nil,
            errors: ["Cannot merge an album with itself"]
          )
        end

        ActiveRecord::Base.transaction do
          lock_albums
          collect_affected_ranking_configurations
          merge_all_associations
          destroy_source_album
          @transaction_body_completed = true
        end

        run_post_commit_steps

        Result.new(success?: true, data: target_album, errors: [])
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
      # destroy! silently affects zero rows -- music_albums has no lock_version, so
      # Rails never checks the affected count -- reporting a completed merge that
      # moved nothing. Ascending id order stops two merges with swapped source and
      # target from deadlocking each other.
      def lock_albums
        [source_album, target_album].sort_by(&:id).each(&:lock!)
      end

      # The merge is committed by this point. Reindexing and ranking recalculation
      # are follow-up work: if they fail the merge still happened, so a failure here
      # must not be reported as a failed merge. `success?` means "the merge
      # committed", and that is what the admin UI reports.
      def run_post_commit_steps
        reindex_target_album
        schedule_ranking_recalculation
        regenerate_user_favorites_list
      rescue => error
        Rails.logger.error(
          "Music::Album::Merger: merge of #{@source_album_id} into #{target_album.id} " \
          "committed, but post-commit follow-up failed: #{error.class}: #{error.message}"
        )
        @stats[:post_commit_error] = error.message
      end

      # SearchIndexable's after_commit callbacks fire as the transaction block exits,
      # which is AFTER the commit, and Rails propagates anything they raise out of
      # that block straight into the rescues above. Reporting success?: false there
      # would tell the admin a merge failed when the source is already permanently
      # deleted, and their retry would fail with "not found".
      #
      # Both halves of merge_committed? are load-bearing. The flag alone would
      # misread a COMMIT that itself failed as success; the missing row alone would
      # misread a merge that never started because a concurrent merge had already
      # consumed the source -- which is what lock_albums raises on.
      def result_for_raised(error, message)
        return Result.new(success?: false, data: nil, errors: [message]) unless merge_committed?

        Rails.logger.error(
          "Music::Album::Merger: merge of #{@source_album_id} into #{target_album.id} " \
          "committed, but a commit callback failed: #{error.class}: #{error.message}"
        )
        @stats[:post_commit_error] = error.message
        Result.new(success?: true, data: target_album, errors: [])
      end

      def merge_committed?
        @transaction_body_completed && !::Music::Album.exists?(@source_album_id)
      end

      def merge_all_associations
        merge_releases
        merge_identifiers
        merge_category_items
        merge_images
        merge_external_links
        merge_list_items
        merge_user_list_items
        merge_release_year

        target_album.save! if target_album.changed?
      end

      def merge_releases
        count = source_album.releases.update_all(album_id: target_album.id)
        @stats[:releases] = count
      end

      def merge_identifiers
        count = source_album.identifiers.update_all(
          identifiable_id: target_album.id
        )
        @stats[:identifiers] = count
      end

      def merge_category_items
        count = 0
        source_album.category_items.find_each do |category_item|
          target_album.category_items.find_or_create_by!(
            category_id: category_item.category_id
          )
          count += 1
        end
        @stats[:category_items] = count
      end

      def merge_images
        has_target_primary = target_album.primary_image.present?

        source_album.images.find_each do |image|
          image.update!(
            parent_id: target_album.id,
            primary: has_target_primary ? false : image.primary
          )
        end

        @stats[:images] = source_album.images.count
      end

      def merge_external_links
        count = source_album.external_links.update_all(parent_id: target_album.id)
        @stats[:external_links] = count
      end

      def merge_list_items
        count = 0
        source_album.list_items.find_each do |list_item|
          # An auto-generated list's rows belong to the generator, which rewrites
          # them nightly from the underlying user favorites -- and this merge has
          # already moved those. Writing here would raise against the ListItem
          # guard and turn an admin merge into a 500.
          next if list_item.list.auto_generated?

          existing = target_album.list_items.find_by(list_id: list_item.list_id)

          if existing
            # Preserve verified=true if source has it and target doesn't
            existing.update!(verified: true) if list_item.verified? && !existing.verified?
          else
            target_album.list_items.create!(
              list_id: list_item.list_id,
              position: list_item.position,
              verified: list_item.verified
            )
          end
          count += 1
        end
        @stats[:list_items] = count
      end

      # Personal favorites rows. music_albums declares
      # `has_many :user_list_items, dependent: :destroy`, so without this the
      # source's destroy! wipes every user's favorites entry for the merged album.
      #
      # position is scoped to the user_list, which does not change, so a moved row
      # keeps a valid position.
      def merge_user_list_items
        count = 0
        source_album.user_list_items.find_each do |entry|
          if ::UserListItem.exists?(user_list_id: entry.user_list_id, listable: target_album)
            entry.destroy!
          else
            entry.update!(listable_id: target_album.id)
            count += 1
          end
        end
        @stats[:user_list_items] = count
      end

      def merge_release_year
        return unless source_album.release_year.present?

        if target_album.release_year.nil? || source_album.release_year < target_album.release_year
          target_album.release_year = source_album.release_year
          @stats[:release_year_updated] = true
        end
      end

      def collect_affected_ranking_configurations
        source_configs = RankedItem.where(item_type: "Music::Album", item_id: source_album.id)
          .pluck(:ranking_configuration_id)
        target_configs = RankedItem.where(item_type: "Music::Album", item_id: target_album.id)
          .pluck(:ranking_configuration_id)

        @affected_ranking_configurations = (source_configs + target_configs).uniq
      end

      def reindex_target_album
        SearchIndexRequest.create!(
          parent: target_album,
          action: :index_item
        )
      end

      def schedule_ranking_recalculation
        @affected_ranking_configurations.each do |config_id|
          BulkCalculateWeightsJob.perform_async(config_id)
          CalculateRankingsJob.perform_in(5.minutes, config_id)
        end
      end

      # The generated "Our Users' Favorites" list is derived data: merge_list_items
      # above deliberately skips (rather than repoints) a source row that sits on
      # that list, so the row is destroyed along with the source album and the
      # generated list falls one item short. Only a full rebuild -- not a repointed
      # row -- produces the correct combined score, voter_count and position for
      # the target album, so the list is regenerated here rather than waiting for
      # the nightly cron. Queuing it now runs it comfortably inside the 5 minutes
      # before schedule_ranking_recalculation's CalculateRankingsJob would otherwise
      # read that short list and bake the wrong result into the rankings.
      def regenerate_user_favorites_list
        GenerateUserFavoritesListsJob.perform_async("Music::Albums::UserList")
      end

      def destroy_source_album
        source_album.destroy!
      end
    end
  end
end
