# frozen_string_literal: true

module Services
  module Books
    # Spec §5: a book with more direct locations than max_direct_locations
    # (Running The World had 361) gets one AI call that keeps its primary
    # settings. Only `legacy` links are removed -- an admin's pick always
    # stays -- and the reconciler then drops inherited ancestors nothing needs.
    # A completed run (a trim, or a guard hit as a skipped row) writes an
    # Enrichment ledger row, so a book is trimmed once. Failed AI calls and dry
    # runs write none and are retried.
    class TrimLocations
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      KIND = "books.location_trim"

      def self.call(book:, dry_run: false, force: false)
        new(book: book, dry_run: dry_run, force: force).call
      end

      def self.candidate_ids(limit: nil, force: false)
        scope = direct_location_links
        unless force
          trimmed = ::Enrichment.for_kind(KIND).where(enrichable_type: "Books::Book").select(:enrichable_id)
          scope = scope.where.not(item_id: trimmed)
        end
        scope = scope
          .group(:item_id)
          .having("COUNT(*) > ?", Rails.configuration.x.categories_cleanup.max_direct_locations)
          .order(Arel.sql("COUNT(*) DESC"))
        scope = scope.limit(limit) if limit
        scope.pluck(:item_id)
      end

      def self.direct_location_links
        ::CategoryItem.direct.joins(:category).where(
          item_type: "Books::Book",
          categories: {type: "Books::Category", category_type: ::Category.category_types.fetch("location"), deleted: false}
        )
      end

      def initialize(book:, dry_run:, force:)
        @book = book
        @dry_run = dry_run
        @force = force
      end

      def call
        return skipped("already trimmed") if !@force && @book.enrichments.for_kind(KIND).exists?

        links = self.class.direct_location_links.where(item_id: @book.id).includes(:category).to_a
        return skipped("not over the limit") if links.size <= Rails.configuration.x.categories_cleanup.max_direct_locations

        result = ::Services::Ai::Tasks::Books::LocationTrimTask.new(book: @book, locations: offered(links)).call
        return Result.new(success?: false, data: {}, errors: [result.error]) unless result.success?

        keep = result.data[:keep_ids]
        if result.data[:raw_count].to_i.positive? && keep.empty?
          reason = "model returned no offered ids"
          record_review(result, links, reason)
          return Result.new(success?: false, data: {}, errors: [reason])
        end
        if keep.empty? && !nonfiction?
          reason = "needs review: empty keep on a book not marked nonfiction"
          record_review(result, links, reason)
          return skipped(reason)
        end
        removable = links.select { |link| link.source_legacy? && !keep.include?(link.category_id) }
        data = {kept: keep, removed: removable.map(&:category_id), reason: result.data[:reason]}
        return Result.new(success?: true, data: data.merge(dry_run: true), errors: []) if @dry_run

        ::CategoryItem.transaction do
          ::CategoryItem.where(id: removable.map(&:id)).destroy_all
          ::Categories::AncestorReconciler.call(item_ids: [@book.id])
          @book.enrichments.create!(
            kind: KIND, mode: :knowledge, outcome: removable.any? ? :applied : :nothing_to_apply,
            facts: {kept: keep, removed: data[:removed]}, ai_chat: result.ai_chat,
            provider: result.ai_chat&.provider, model: result.ai_chat&.model
          )
        end
        Result.new(success?: true, data: data, errors: [])
      end

      private

      # A guard hit gets a skipped ledger row (the review queue) so the book
      # leaves candidate_ids until FORCE=1. A dry run writes nothing.
      def record_review(result, links, reason)
        return if @dry_run

        @book.enrichments.create!(
          kind: KIND, mode: :knowledge, outcome: :skipped, reason: reason,
          facts: {raw_count: result.data[:raw_count], offered_ids: links.map(&:category_id)},
          ai_chat: result.ai_chat, provider: result.ai_chat&.provider, model: result.ai_chat&.model
        )
      end

      def nonfiction?
        id = ::Books::BookType.category_id(1)
        id.present? && ::CategoryItem.exists?(item: @book, category_id: id)
      end

      def offered(links)
        trails = ::Books::LocationTrails.call(links.map(&:category), keep_root: true)
        links.map do |link|
          trail = trails.fetch(link.category_id, [link.category]).map(&:name).join(", ")
          ::Services::Ai::Tasks::Books::LocationTrimTask::Location.new(id: link.category_id, trail: trail, fixed: !link.source_legacy?)
        end
      end

      def skipped(reason)
        Result.new(success?: true, data: {skipped: reason}, errors: [])
      end
    end
  end
end
