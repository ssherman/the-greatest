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
        @stats = {}
        @affected_ranking_configurations = []
      end

      def call
        ActiveRecord::Base.transaction do
          collect_affected_ranking_configurations
          merge_all_associations
          destroy_source_album
        end

        reindex_target_album
        schedule_ranking_recalculation

        Result.new(success?: true, data: target_album, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        Result.new(success?: false, data: nil, errors: [error.message])
      rescue ActiveRecord::RecordNotUnique => error
        Result.new(success?: false, data: nil, errors: ["Constraint violation: #{error.message}"])
      rescue => error
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      def merge_all_associations
        merge_releases
        merge_identifiers
        merge_category_items
        merge_images
        merge_external_links
        merge_list_items
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
          target_album.list_items.find_or_create_by!(
            list_id: list_item.list_id
          ) do |new_list_item|
            new_list_item.position = list_item.position
          end
          count += 1
        end
        @stats[:list_items] = count
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

      def destroy_source_album
        source_album.destroy!
      end
    end
  end
end
