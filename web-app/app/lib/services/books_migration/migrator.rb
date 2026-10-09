module Services
  module BooksMigration
    # Base for one-way old->new entity migrators. Streams legacy rows in batches
    # (as String-keyed attribute hashes), transforms + upserts each through the
    # real new-model AR class, with search indexing suppressed for the load.
    # Idempotent — safe to re-run. Subclasses define legacy_model, model_key, and
    # upsert_row(attrs); optionally finalize and extra_result_data.
    class Migrator
      BATCH_SIZE = 1000

      def self.call(sync: nil)
        new(sync: sync).call
      end

      # sync: a SyncScope when data_migration:sync runs this migrator (spec §5), nil
      # for the full migration.
      def initialize(sync: nil)
        @sync = sync
      end

      def call
        @count = 0
        Services::BooksMigration.without_search_indexing do
          legacy_each do |attrs|
            next unless in_sync_scope?(attrs)

            upsert_row(attrs)
            @count += 1
          rescue => e
            raise "#{model_key} migration failed at legacy id=#{attrs["id"]} (#{@count} rows succeeded): #{e.message}"
          end
        end
        finalize
        {success: true, data: {model: model_key, count: @count}.merge(extra_result_data)}
      rescue => e
        {success: false, error: e.message, data: {model: model_key, count: @count}}
      end

      private

      attr_reader :sync

      # Yields each legacy row's attributes (String keys). Stubbed in tests so the
      # legacy connection is never opened.
      def legacy_each(&block)
        sync_narrowed(legacy_model).find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      # [SyncScope id set, legacy column] naming the rows that belong to a sync run,
      # e.g. [:book_ids, "book_id"]. nil: every row (the migrator decides per row).
      def sync_filter
        nil
      end

      def in_sync_scope?(attrs)
        return true unless sync && sync_filter

        ids, column = sync_filter
        sync.public_send(ids).include?(attrs[column])
      end

      # Asks legacy for the run's rows only. in_sync_scope? still decides; this just
      # keeps a weekly run from reading every legacy row.
      def sync_narrowed(relation)
        return relation unless sync && sync_filter

        ids, column = sync_filter
        relation.where(column => sync.public_send(ids).to_a)
      end

      def finalize
      end

      # Extra keys a subclass wants in the success result's data (counts it kept
      # during finalize, for instance). Default: none.
      def extra_result_data
        {}
      end
    end
  end
end
