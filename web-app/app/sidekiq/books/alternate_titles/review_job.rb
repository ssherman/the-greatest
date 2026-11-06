# frozen_string_literal: true

module Books
  module AlternateTitles
    # The AI review of one book's alternate titles (Services::Books::AlternateTitles::Review).
    # A failed AI call raises so Sidekiq retries; the review writes nothing
    # until every call has succeeded, so a retry starts clean.
    class ReviewJob
      include Sidekiq::Job

      sidekiq_options queue: :low, retry: 3

      BATCH = 1_000

      # Book ids that still need a review: ranked books first, by rank in the
      # default primary configuration, then the rest by id.
      #   "ranked" - the first group only
      #   "all"    - both groups
      #   "500"    - the first 500 of "all"
      def self.pending_book_ids(scope)
        scope = scope.to_s
        unless %w[ranked all].include?(scope) || scope.match?(/\A[1-9]\d*\z/)
          raise ArgumentError, "scope must be ranked, all or a count, got #{scope.inspect}"
        end

        pending = pending_ids
        ranked = ranked_ids(pending)
        return ranked if scope == "ranked"

        ordered = ranked + (pending - ranked).sort
        scope.match?(/\A\d+\z/) ? ordered.first(scope.to_i) : ordered
      end

      # Returns the number of books queued.
      def self.enqueue(scope)
        ids = pending_book_ids(scope)
        ids.each_slice(BATCH) { |slice| perform_bulk(slice.zip) }
        ids.size
      end

      def self.pending_ids
        unjudged = ::AlternateTitle.where(titleable_type: "Books::Book").unjudged.distinct.pluck(:titleable_id)
        with_rows = ::AlternateTitle.where(titleable_type: "Books::Book").select(:titleable_id)
        never_backfilled = ::Books::Book.where("cardinality(alternate_titles) > 0").where.not(id: with_rows).pluck(:id)
        (unjudged + never_backfilled).uniq
      end
      private_class_method :pending_ids

      def self.ranked_ids(pending)
        config_id = ::Books::RankingConfiguration.default_primary&.id
        return [] unless config_id

        RankedItem.where(item_type: "Books::Book", ranking_configuration_id: config_id, item_id: pending)
          .where.not(rank: nil).order(:rank, :item_id).pluck(:item_id)
      end
      private_class_method :ranked_ids

      def perform(book_id)
        book = ::Books::Book.find_by(id: book_id)
        return unless book

        result = ::Services::Books::AlternateTitles::Review.call(book: book)
        return if result.success?

        raise "alternate title review failed for book #{book.id}: #{Array(result.errors).join("; ")}"
      end
    end
  end
end
