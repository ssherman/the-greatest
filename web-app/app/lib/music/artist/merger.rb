module Music
  class Artist
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      attr_reader :source_artist, :target_artist, :stats

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_artist = source
        @target_artist = target
        @stats = {}
        @affected_ranking_configurations = []
      end

      def call
        if source_artist.id == target_artist.id
          return Result.new(
            success?: false,
            data: nil,
            errors: ["Cannot merge an artist with itself"]
          )
        end

        ActiveRecord::Base.transaction do
          collect_affected_ranking_configurations
          merge_all_associations
          destroy_source_artist
        end

        reindex_target_artist
        schedule_ranking_recalculation

        Result.new(success?: true, data: target_artist, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        Result.new(success?: false, data: nil, errors: [error.message])
      rescue ActiveRecord::RecordNotUnique => error
        Result.new(success?: false, data: nil, errors: ["Constraint violation: #{error.message}"])
      rescue => error
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      def merge_all_associations
        merge_album_artists
        merge_song_artists
        merge_band_memberships
        merge_memberships
        merge_credits
        merge_identifiers
        merge_category_items
        merge_images
        merge_external_links

        target_artist.touch
      end

      def merge_album_artists
        count = 0
        source_artist.album_artists.find_each do |album_artist|
          existing = target_artist.album_artists.find_by(album_id: album_artist.album_id)

          if existing
            album_artist.destroy!
          else
            album_artist.update!(artist_id: target_artist.id)
            count += 1
          end
        end
        @stats[:album_artists] = count
      end

      def merge_song_artists
        count = 0
        source_artist.song_artists.find_each do |song_artist|
          existing = target_artist.song_artists.find_by(song_id: song_artist.song_id)

          if existing
            song_artist.destroy!
          else
            song_artist.update!(artist_id: target_artist.id)
            count += 1
          end
        end
        @stats[:song_artists] = count
      end

      def merge_band_memberships
        count = 0
        source_artist.band_memberships.find_each do |membership|
          existing = target_artist.band_memberships.find_by(member_id: membership.member_id)

          if existing
            membership.destroy!
          else
            membership.update!(artist_id: target_artist.id)
            count += 1
          end
        end
        @stats[:band_memberships] = count
      end

      def merge_memberships
        count = 0
        source_artist.memberships.find_each do |membership|
          next if membership.artist_id == target_artist.id

          existing = target_artist.memberships.find_by(artist_id: membership.artist_id)

          if existing
            membership.destroy!
          else
            membership.update!(member_id: target_artist.id)
            count += 1
          end
        end
        @stats[:memberships] = count
      end

      def merge_credits
        count = source_artist.credits.update_all(artist_id: target_artist.id)
        @stats[:credits] = count
      end

      def merge_identifiers
        count = 0
        source_artist.identifiers.find_each do |identifier|
          existing = target_artist.identifiers.find_by(
            identifier_type: identifier.identifier_type,
            value: identifier.value
          )

          if existing
            identifier.destroy!
          else
            identifier.update!(identifiable_id: target_artist.id)
            count += 1
          end
        end
        @stats[:identifiers] = count
      end

      def merge_category_items
        count = 0
        source_artist.category_items.find_each do |category_item|
          target_artist.category_items.find_or_create_by!(
            category_id: category_item.category_id
          )
          count += 1
        end
        @stats[:category_items] = count
      end

      def merge_images
        has_target_primary = target_artist.primary_image.present?

        source_artist.images.find_each do |image|
          image.update!(
            parent_id: target_artist.id,
            primary: has_target_primary ? false : image.primary
          )
        end

        @stats[:images] = source_artist.images.count
      end

      def merge_external_links
        count = source_artist.external_links.update_all(parent_id: target_artist.id)
        @stats[:external_links] = count
      end

      def collect_affected_ranking_configurations
        source_configs = RankedItem.where(item_type: "Music::Artist", item_id: source_artist.id)
          .pluck(:ranking_configuration_id)
        target_configs = RankedItem.where(item_type: "Music::Artist", item_id: target_artist.id)
          .pluck(:ranking_configuration_id)

        @affected_ranking_configurations = (source_configs + target_configs).uniq
      end

      def reindex_target_artist
        SearchIndexRequest.create!(
          parent: target_artist,
          action: :index_item
        )
      end

      def schedule_ranking_recalculation
        @affected_ranking_configurations.each do |config_id|
          BulkCalculateWeightsJob.perform_async(config_id)
          CalculateRankingsJob.perform_in(5.minutes, config_id)
        end
      end

      def destroy_source_artist
        source_artist.destroy!
      end
    end
  end
end
