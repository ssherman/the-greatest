module Services
  module Reviews
    # The only writer of review_summaries. Two paths that must agree:
    #
    #   .recalculate(type, id) -- one row, fired from Review#after_commit.
    #   .backfill_all!         -- full set-based rebuild, used after the increment-2
    #                             migration (which bulk-inserts and so never fires the
    #                             callback). NOT YET exposed as a rake task -- that is
    #                             increment 2.
    #
    # Invariant: a summary row exists iff at least one review exists for that
    # reviewable.
    #
    # Both paths are the SAME two unconditional statements -- an upsert and a prune --
    # differing only in whether they are scoped to one reviewable. That is deliberate:
    #
    #   * The upsert's GROUP BY yields no group when the reviewable has no reviews, so
    #     nothing is inserted. An earlier version bound :type/:id as literals with no
    #     GROUP BY, which made it a scalar aggregate -- always returning one row, so a
    #     reviewable with zero reviews got a ghost all-zero summary.
    #   * The prune removes any row left orphaned.
    #
    # There is deliberately NO `if Review.exists?` branch. Check-then-act across two
    # statements is a TOCTOU race: under READ COMMITTED each statement takes a fresh
    # snapshot, so a concurrent write committing in between could insert a ghost row
    # (reviews vanished after the check) or delete a live one (a review arrived after
    # the check). Two unconditional statements have no such window.
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

      # Serializes recalculations per reviewable. Without it, the upsert's SELECT
      # computes the aggregate BEFORE ON CONFLICT takes the row lock, so two callbacks
      # for the same reviewable can compute in one order and commit in the other -- the
      # one holding the older snapshot lands last and leaves the counters stale until
      # the next write or a full backfill. Taking the lock first means whichever
      # transaction writes last also computed last.
      #
      # Hashed to a single bigint rather than using the (int4, int4) form: reviewable_id
      # is a bigint and would overflow int4. A hash collision only serializes two
      # unrelated reviewables briefly, which is harmless.
      #
      # xact-scoped, so it releases on COMMIT or ROLLBACK with no explicit unlock.
      # backfill_all! deliberately does NOT take it -- it is a single set-based rebuild
      # over every reviewable, not a per-row read-modify-write.
      ADVISORY_LOCK = "SELECT pg_advisory_xact_lock(hashtext(:type || ':' || :id::text))"

      def self.recalculate(reviewable_type, reviewable_id)
        new.recalculate(reviewable_type, reviewable_id)
      end

      def self.backfill_all!
        new.backfill_all!
      end

      def recalculate(reviewable_type, reviewable_id)
        binds = {type: reviewable_type, id: reviewable_id}

        ReviewSummary.transaction do
          connection.execute(sanitize(ADVISORY_LOCK, binds))
          connection.execute(
            sanitize(upsert_sql("WHERE reviewable_type = :type AND reviewable_id = :id"), binds)
          )
          connection.execute(
            sanitize(prune_sql("AND s.reviewable_type = :type AND s.reviewable_id = :id"), binds)
          )
        end
      end

      def backfill_all!
        ReviewSummary.transaction do
          connection.execute(upsert_sql)
          connection.execute(prune_sql)
        end

        ReviewSummary.count
      end

      private

      def connection
        ReviewSummary.connection
      end

      def sanitize(sql, binds)
        ReviewSummary.sanitize_sql_array([sql, binds])
      end

      # `scope` is a trusted SQL fragment written in this class, never user input; the
      # runtime values it references arrive as named binds through #sanitize.
      def upsert_sql(scope = "")
        <<~SQL
          INSERT INTO review_summaries (#{COLUMNS})
          SELECT reviewable_type, reviewable_id, #{AGGREGATES}
          FROM reviews
          #{scope}
          GROUP BY reviewable_type, reviewable_id
          #{ON_CONFLICT}
        SQL
      end

      def prune_sql(scope = "")
        <<~SQL
          DELETE FROM review_summaries s
          WHERE NOT EXISTS (
            SELECT 1 FROM reviews r
            WHERE r.reviewable_type = s.reviewable_type
              AND r.reviewable_id = s.reviewable_id
          )
          #{scope}
        SQL
      end
    end
  end
end
