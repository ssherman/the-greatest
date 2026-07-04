module Services
  module BooksMigration
    # Base for one-way old->new entity migrators. Streams legacy rows in batches
    # (as String-keyed attribute hashes), transforms + upserts each through the
    # real new-model AR class, with search indexing suppressed for the load.
    # Idempotent — safe to re-run. Subclasses define legacy_model, model_key, and
    # upsert_row(attrs); optionally finalize.
    class Migrator
      BATCH_SIZE = 1000

      def self.call
        new.call
      end

      def call
        @count = 0
        Services::BooksMigration.without_search_indexing do
          legacy_each do |attrs|
            upsert_row(attrs)
            @count += 1
          rescue => e
            raise "#{model_key} migration failed at legacy id=#{attrs["id"]} (#{@count} rows succeeded): #{e.message}"
          end
        end
        finalize
        {success: true, data: {model: model_key, count: @count}}
      rescue => e
        {success: false, error: e.message, data: {model: model_key, count: @count}}
      end

      private

      # Yields each legacy row's attributes (String keys). Stubbed in tests so the
      # legacy connection is never opened.
      def legacy_each(&block)
        legacy_model.find_each(batch_size: BATCH_SIZE) { |record| block.call(record.attributes) }
      end

      def finalize
      end
    end
  end
end
