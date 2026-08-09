module Services
  module Reviews
    # The only writer of review_summaries. Two paths that must agree:
    #
    #   .recalculate(type, id) -- one row, fired from Review#after_commit.
    #   .backfill_all!         -- full set-based rebuild, used after the increment-2
    #                             migration (which bulk-inserts and so never fires the
    #                             callback) and exposed as a rake task.
    #
    # Invariant: a summary row exists iff at least one review exists for that
    # reviewable. recalculate deletes when the last review goes; backfill_all! prunes
    # orphans after upserting. Drop either half and the two paths diverge.
    class SummaryRecalculator
      AGGREGATES = <<~SQL.freeze
        COUNT(*),
        COALESCE(SUM(rating), 0),
        COUNT(*) FILTER (WHERE body IS NOT NULL),
        COUNT(*) FILTER (WHERE rating = 1),
        COUNT(*) FILTER (WHERE rating = 2),
        COUNT(*) FILTER (WHERE rating = 3),
        COUNT(*) FILTER (WHERE rating = 4),
        COUNT(*) FILTER (WHERE rating = 5),
        NOW(), NOW()
      SQL

      COLUMNS = <<~SQL.freeze
        reviewable_type, reviewable_id,
        ratings_count, ratings_sum, text_reviews_count,
        rating_1_count, rating_2_count, rating_3_count, rating_4_count, rating_5_count,
        created_at, updated_at
      SQL

      ON_CONFLICT = <<~SQL.freeze
        ON CONFLICT (reviewable_type, reviewable_id) DO UPDATE SET
          ratings_count      = EXCLUDED.ratings_count,
          ratings_sum        = EXCLUDED.ratings_sum,
          text_reviews_count = EXCLUDED.text_reviews_count,
          rating_1_count     = EXCLUDED.rating_1_count,
          rating_2_count     = EXCLUDED.rating_2_count,
          rating_3_count     = EXCLUDED.rating_3_count,
          rating_4_count     = EXCLUDED.rating_4_count,
          rating_5_count     = EXCLUDED.rating_5_count,
          updated_at         = NOW()
      SQL

      def self.recalculate(reviewable_type, reviewable_id)
        new.recalculate(reviewable_type, reviewable_id)
      end

      def self.backfill_all!
        new.backfill_all!
      end

      def recalculate(reviewable_type, reviewable_id)
        scope = ReviewSummary.where(reviewable_type: reviewable_type, reviewable_id: reviewable_id)

        ReviewSummary.transaction do
          if Review.where(reviewable_type: reviewable_type, reviewable_id: reviewable_id).exists?
            connection.execute(upsert_one_sql(reviewable_type, reviewable_id))
          else
            scope.delete_all
          end
        end
      end

      def backfill_all!
        ReviewSummary.transaction do
          connection.execute(upsert_all_sql)
          connection.execute(prune_sql)
        end

        ReviewSummary.count
      end

      private

      def connection
        ReviewSummary.connection
      end

      def upsert_one_sql(reviewable_type, reviewable_id)
        ReviewSummary.sanitize_sql_array([<<~SQL, type: reviewable_type, id: reviewable_id])
          INSERT INTO review_summaries (#{COLUMNS})
          SELECT :type, :id, #{AGGREGATES}
          FROM reviews
          WHERE reviewable_type = :type AND reviewable_id = :id
          #{ON_CONFLICT}
        SQL
      end

      def upsert_all_sql
        <<~SQL
          INSERT INTO review_summaries (#{COLUMNS})
          SELECT reviewable_type, reviewable_id, #{AGGREGATES}
          FROM reviews
          GROUP BY reviewable_type, reviewable_id
          #{ON_CONFLICT}
        SQL
      end

      def prune_sql
        <<~SQL
          DELETE FROM review_summaries s
          WHERE NOT EXISTS (
            SELECT 1 FROM reviews r
            WHERE r.reviewable_type = s.reviewable_type
              AND r.reviewable_id = s.reviewable_id
          )
        SQL
      end
    end
  end
end
