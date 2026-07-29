module Services
  module BooksMigration
    # BulkUpsertMigrator that writes with insert_all (ON CONFLICT DO NOTHING) instead of
    # upsert_all. Everything else -- streaming, batching, per-batch statements, the Result
    # hash, fail-loud error wrapping -- is inherited unchanged.
    #
    # Why, for the description backfill it exists to serve: upsert_all's ON CONFLICT DO
    # UPDATE writes every supplied column, so a re-run would reset an editor's
    # rank: :preferred back to :normal and overwrite edited content, violating D5. It can
    # also transiently double-occupy index_descriptions_one_preferred_per_key (D14), raising
    # a PG::UniqueViolation that ON CONFLICT cannot absorb -- the arbiter is the other index
    # -- aborting the whole batch. Switching to insert_all does not close this specific
    # hazard: the ON CONFLICT arbiter is the natural-key index either way, so a new
    # rank: :preferred row landing on a record that already carries a preferred row from a
    # different source still raises PG::UniqueViolation against the other index and aborts
    # the batch. Not reachable today -- no Books::Book had any Description row before this
    # run -- and closed before increment (c) ships the admin set-preferred UI, which
    # demotes-then-promotes inside a transaction. These backfills are a one-time lift, so skip-on-conflict
    # is the correct semantic: later runs leave existing rows alone while still picking up
    # records and sources that are new since the last run, and no finalize pass is needed.
    # Were re-syncing changed source text ever wanted, the safe form is
    # upsert_all(rows, unique_by: ..., update_only: [:content]) -- it refreshes text without
    # touching rank.
    #
    # Switching to insert_all also removes the intra-batch PG::CardinalityViolation that
    # ListPenaltyMigrator needed an @seen set for: DO NOTHING skips a repeated conflict key
    # rather than raising. A subclass that reintroduces upsert_all must reintroduce the
    # dedup with it.
    #
    # ActiveRecord::Result#length is the number of rows Postgres actually inserted, so
    # @count -- and the Result hash built from it -- honestly reports 0 on a no-op re-run
    # rather than re-counting skipped rows.
    class InsertOnlyMigrator < BulkUpsertMigrator
      private

      def flush(rows)
        result = target_model.insert_all(rows, unique_by: unique_by, record_timestamps: record_timestamps?)
        @count += result.length
      end
    end
  end
end
