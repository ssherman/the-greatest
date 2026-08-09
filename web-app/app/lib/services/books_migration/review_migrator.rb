module Services
  module BooksMigration
    # Legacy `reviews` -> the global polymorphic `reviews` table (reviewable =
    # ::Books::Book, which preserves its legacy id, so no LegacyIdMap lookup is needed).
    # Legacy review ids and timestamps are preserved too.
    #
    # unique_by is nil ON PURPOSE. Preserved ids mean a re-run collides on BOTH
    # reviews_pkey and index_reviews_on_user_and_reviewable, and an arbiter naming only
    # one of them lets the other raise and abort the batch. Untargeted
    # ON CONFLICT DO NOTHING absorbs either.
    #
    # Dedup is done here in Ruby rather than with DISTINCT ON in the legacy query: every
    # migrator test stubs legacy_each, so a SQL-level filter could not be tested at all.
    # Rows arrive newest-first and @seen keeps the first occurrence of each natural key,
    # which is the newer row. 123 legacy pairs are affected; none has body text on either
    # side, and 41 disagree on rating, so "newer wins" has to be a stated rule rather
    # than whatever ON CONFLICT happens to keep.
    #
    # insert_all bypasses Review's before_validation AND its after_commit, so the body is
    # sanitized explicitly here and review_summaries is rebuilt afterwards by
    # SummaryRecalculator.backfill_all! (see the data_migration:reviews rake task).
    class ReviewMigrator < InsertOnlyMigrator
      private

      def legacy_model
        LegacyBooks::Review
      end

      def model_key
        "Review"
      end

      def target_model
        ::Review
      end

      # See the class comment. Not a mistake, not an omission.
      def unique_by
        nil
      end

      # Legacy created_at/updated_at are supplied in build_rows and must survive.
      def record_timestamps?
        false
      end

      def preload_context
        @book_ids = ::Books::Book.pluck(:id).to_set
        @seen = Set.new
      end

      # insert_all with explicit ids never advances the sequence, so without this the
      # first review a real user writes gets id 1 and collides with a migrated row.
      # finalize runs outside without_search_indexing, so keep it callback-free.
      def finalize
        target_model.connection.reset_pk_sequence!("reviews")
      end

      # Newest-first so the dedup below keeps the newer of a duplicated pair.
      def legacy_each(&block)
        legacy_model.find_each(batch_size: BATCH_SIZE, order: :desc) do |record|
          block.call(record.attributes)
        end
      end

      def build_rows(attrs)
        book_id = attrs["book_id"]
        unless @book_ids.include?(book_id)
          raise "no migrated ::Books::Book for legacy reviews.book_id=#{book_id.inspect}"
        end

        # First occurrence wins, and rows arrive newest-first.
        return [] unless @seen.add?([attrs["user_id"], book_id])

        [{
          id: attrs["id"],
          user_id: attrs["user_id"],
          reviewable_type: "Books::Book",
          reviewable_id: book_id,
          title: attrs["title"]&.strip.presence,
          body: body_for(attrs),
          rating: attrs["rating"],
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }]
      end

      # The cap runs AFTER sanitizing: <script> contents survive sanitizing as visible
      # text, so the 462KB fuzz paste is only over-length once cleaned. One legacy row
      # (101561) is affected; it imports as rating-only.
      def body_for(attrs)
        body = Services::Reviews::BodySanitizer.call(attrs["body"])
        return nil if body.nil?

        if body.length > ::Review::MAX_BODY_LENGTH
          Rails.logger.warn(
            "ReviewMigrator: dropped body of legacy review id=#{attrs["id"]} " \
            "(#{body.length} chars after sanitizing, cap #{::Review::MAX_BODY_LENGTH})"
          )
          return nil
        end

        body
      end
    end
  end
end
