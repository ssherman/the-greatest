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
        @stats = {}
        @affected_ranking_configurations = []
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
          collect_affected_ranking_configurations
          merge_all_associations
          reconcile_scalars
          target_game.save! if target_game.changed?
          destroy_source_game
        end

        reindex_target_game
        schedule_ranking_recalculation

        Result.new(success?: true, data: target_game, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        Result.new(success?: false, data: nil, errors: [error.message])
      rescue ActiveRecord::RecordNotUnique => error
        Result.new(success?: false, data: nil, errors: ["Constraint violation: #{error.message}"])
      rescue => error
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      def merge_all_associations
        merge_identifiers
        merge_external_links
        merge_images
        merge_category_items
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

      def reconcile_scalars
      end

      def collect_affected_ranking_configurations
      end

      def reindex_target_game
      end

      def schedule_ranking_recalculation
      end

      def destroy_source_game
        source_game.destroy!
      end
    end
  end
end
