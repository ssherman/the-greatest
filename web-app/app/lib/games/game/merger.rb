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
          existing = target_game.list_items.find_by(list_id: list_item.list_id)

          if existing
            existing.update!(verified: true) if list_item.verified? && !existing.verified?
          else
            target_game.list_items.create!(
              list_id: list_item.list_id,
              position: list_item.position,
              verified: list_item.verified
            )
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
      # parent, so it is nullified instead.
      def merge_child_games
        children = ::Games::Game.where(parent_game_id: source_game.id)

        children.where(id: target_game.id).update_all(parent_game_id: nil)
        count = children.where.not(id: target_game.id).update_all(parent_game_id: target_game.id)

        target_game.reload if target_game.parent_game_id == source_game.id
        @stats[:child_games] = count
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
