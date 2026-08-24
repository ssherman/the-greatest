module Books
  class Author
    class Merger
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      attr_reader :source_author, :target_author, :stats

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source_author = source
        @target_author = target
        @stats = {}
        @affected_book_ids = []
      end

      def call
        if source_author.id == target_author.id
          return Result.new(
            success?: false,
            data: nil,
            errors: ["Cannot merge an author with itself"]
          )
        end

        ActiveRecord::Base.transaction do
          merge_all_associations
          reconcile_scalars
          target_author.save! if target_author.changed?
          destroy_source_author
        end

        run_post_commit_steps

        Result.new(success?: true, data: target_author, errors: [])
      rescue ActiveRecord::RecordInvalid => error
        Result.new(success?: false, data: nil, errors: [error.message])
      rescue ActiveRecord::RecordNotUnique => error
        Result.new(success?: false, data: nil, errors: ["Constraint violation: #{error.message}"])
      rescue => error
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      # Unlike the games and books mergers there is no
      # collect_affected_ranking_configurations step: author rankings do not derive
      # from lists, so recalculation is one argument-less job rather than a set of
      # per-configuration ones, and there is nothing to capture before the destroy.
      def merge_all_associations
        merge_identifiers
        merge_external_links
        merge_ai_chats
        merge_images
        merge_category_items
      end

      def merge_identifiers
        count = 0
        source_author.identifiers.find_each do |identifier|
          existing = target_author.identifiers.find_by(
            identifier_type: identifier.identifier_type,
            value: identifier.value
          )

          if existing
            identifier.destroy!
          else
            identifier.update!(identifiable_id: target_author.id)
            count += 1
          end
        end
        @stats[:identifiers] = count
      end

      def merge_external_links
        @stats[:external_links] = source_author.external_links.update_all(parent_id: target_author.id)
      end

      def merge_ai_chats
        @stats[:ai_chats] = source_author.ai_chats.update_all(parent_id: target_author.id)
      end

      def merge_images
        has_target_primary = target_author.primary_image.present?
        count = 0

        source_author.images.find_each do |image|
          image.update!(
            parent_id: target_author.id,
            primary: has_target_primary ? false : image.primary
          )
          count += 1
        end

        @stats[:images] = count
      end

      def merge_category_items
        count = 0
        source_author.category_items.find_each do |category_item|
          target_author.category_items.find_or_create_by!(category_id: category_item.category_id)
          count += 1
        end
        @stats[:category_items] = count
      end

      def reconcile_scalars
      end

      def run_post_commit_steps
      end

      def destroy_source_author
        source_author.destroy!
      end
    end
  end
end
