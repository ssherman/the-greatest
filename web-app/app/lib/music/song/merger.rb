module Music
  class Song
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      attr_reader :source_song, :target_song, :stats

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_song = source
        @target_song = target
        @source_song_id = source.id
        @stats = {}
        @affected_ranking_configurations = []
        @transaction_body_completed = false
      end

      def call
        if source_song.id == target_song.id
          return Result.new(
            success?: false,
            data: nil,
            errors: ["Cannot merge a song with itself"]
          )
        end

        ActiveRecord::Base.transaction do
          lock_songs
          collect_affected_ranking_configurations
          merge_all_associations
          destroy_source_song
          @transaction_body_completed = true
        end

        run_post_commit_steps

        Result.new(success?: true, data: target_song, errors: [])
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
      # destroy! silently affects zero rows -- music_songs has no lock_version, so
      # Rails never checks the affected count -- reporting a completed merge that
      # moved nothing. Ascending id order stops two merges with swapped source and
      # target from deadlocking each other.
      def lock_songs
        [source_song, target_song].sort_by(&:id).each(&:lock!)
      end

      # The merge is committed by this point. Ranking recalculation is follow-up
      # work: if it fails the merge still happened, so a failure here must not be
      # reported as a failed merge. `success?` means "the merge committed", and that
      # is what the admin UI reports.
      def run_post_commit_steps
        schedule_ranking_recalculation
      rescue => error
        Rails.logger.error(
          "Music::Song::Merger: merge of #{@source_song_id} into #{target_song.id} " \
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
      # consumed the source -- which is what lock_songs raises on.
      def result_for_raised(error, message)
        return Result.new(success?: false, data: nil, errors: [message]) unless merge_committed?

        Rails.logger.error(
          "Music::Song::Merger: merge of #{@source_song_id} into #{target_song.id} " \
          "committed, but a commit callback failed: #{error.class}: #{error.message}"
        )
        @stats[:post_commit_error] = error.message
        Result.new(success?: true, data: target_song, errors: [])
      end

      def merge_committed?
        @transaction_body_completed && !::Music::Song.exists?(@source_song_id)
      end

      def merge_all_associations
        merge_tracks
        merge_identifiers
        merge_category_items
        merge_external_links
        merge_list_items
        merge_song_relationships
        merge_inverse_song_relationships
        merge_release_year

        target_song.save! if target_song.changed?
        target_song.touch unless target_song.saved_changes?
      end

      def merge_tracks
        count = source_song.tracks.update_all(song_id: target_song.id)
        @stats[:tracks] = count
      end

      def merge_identifiers
        count = 0
        source_song.identifiers.find_each do |identifier|
          existing = target_song.identifiers.find_by(
            identifier_type: identifier.identifier_type,
            value: identifier.value
          )

          if existing
            identifier.destroy!
          else
            identifier.update!(identifiable_id: target_song.id)
            count += 1
          end
        end
        @stats[:identifiers] = count
      end

      def merge_category_items
        count = 0
        source_song.category_items.find_each do |category_item|
          target_song.category_items.find_or_create_by!(
            category_id: category_item.category_id
          )
          count += 1
        end
        @stats[:category_items] = count
      end

      def merge_external_links
        count = source_song.external_links.update_all(parent_id: target_song.id)
        @stats[:external_links] = count
      end

      def merge_list_items
        count = 0
        source_song.list_items.find_each do |list_item|
          # An auto-generated list's rows belong to the generator, which rewrites
          # them nightly from the underlying user favorites -- and this merge has
          # already moved those. Writing here would raise against the ListItem
          # guard and turn an admin merge into a 500.
          next if list_item.list.auto_generated?

          existing = target_song.list_items.find_by(list_id: list_item.list_id)

          if existing
            # Preserve verified=true if source has it and target doesn't
            existing.update!(verified: true) if list_item.verified? && !existing.verified?
          else
            target_song.list_items.create!(
              list_id: list_item.list_id,
              position: list_item.position,
              verified: list_item.verified
            )
          end
          count += 1
        end
        @stats[:list_items] = count
      end

      def merge_song_relationships
        count = 0
        source_song.song_relationships.find_each do |relationship|
          next if relationship.related_song_id == target_song.id

          target_song.song_relationships.find_or_create_by!(
            related_song_id: relationship.related_song_id,
            relation_type: relationship.relation_type
          ) do |new_relationship|
            new_relationship.source_release_id = relationship.source_release_id
          end
          count += 1
        end
        @stats[:song_relationships] = count
      end

      def merge_inverse_song_relationships
        inverse_relationships = Music::SongRelationship.where(related_song_id: source_song.id)

        inverse_relationships.find_each do |relationship|
          if relationship.song_id == target_song.id
            relationship.destroy!
          else
            relationship.update!(related_song_id: target_song.id)
          end
        end

        @stats[:inverse_song_relationships] = inverse_relationships.count
      end

      def merge_release_year
        return unless source_song.release_year.present?

        if target_song.release_year.nil? || source_song.release_year < target_song.release_year
          target_song.release_year = source_song.release_year
          @stats[:release_year_updated] = true
        end
      end

      def collect_affected_ranking_configurations
        source_configs = RankedItem.where(item_type: "Music::Song", item_id: source_song.id)
          .pluck(:ranking_configuration_id)
        target_configs = RankedItem.where(item_type: "Music::Song", item_id: target_song.id)
          .pluck(:ranking_configuration_id)

        @affected_ranking_configurations = (source_configs + target_configs).uniq
      end

      def schedule_ranking_recalculation
        @affected_ranking_configurations.each do |config_id|
          BulkCalculateWeightsJob.perform_async(config_id)
          CalculateRankingsJob.perform_in(5.minutes, config_id)
        end
      end

      def destroy_source_song
        source_song.destroy!
      end
    end
  end
end
