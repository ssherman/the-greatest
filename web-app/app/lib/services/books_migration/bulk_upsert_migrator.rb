module Services
  module BooksMigration
    # Base for high-volume join/child tables: streams legacy rows, maps each to zero
    # or more target row hashes (build_rows), and bulk-upserts them with upsert_all in
    # batches — no per-row AR callbacks, no giant wrapping transaction (each batch is
    # its own statement, so a mid-run failure leaves prior batches committed and the
    # run resumes idempotently). Idempotent on the target's unique index. Subclasses
    # define: legacy_model, model_key, target_model, unique_by, build_rows(attrs);
    # optionally preload_context / finalize / upsert_batch.
    class BulkUpsertMigrator < Migrator
      UPSERT_BATCH = 1000

      def call
        @count = 0
        buffer = []
        preload_context
        Services::BooksMigration.without_search_indexing do
          legacy_each do |attrs|
            build_rows(attrs).each { |row| buffer << row }
            if buffer.size >= upsert_batch
              flush(buffer)
              buffer = []
            end
          rescue => e
            raise "#{model_key} migration failed at legacy id=#{attrs["id"]} (#{@count} rows upserted): #{e.message}"
          end
          flush(buffer) if buffer.any?
        end
        finalize
        {success: true, data: {model: model_key, count: @count}}
      rescue => e
        {success: false, error: e.message, data: {model: model_key, count: @count}}
      end

      private

      def upsert_batch
        UPSERT_BATCH
      end

      def preload_context
      end

      def flush(rows)
        target_model.upsert_all(rows, unique_by: unique_by, record_timestamps: true)
        @count += rows.size
      end
    end
  end
end
