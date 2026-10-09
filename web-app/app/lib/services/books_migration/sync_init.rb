module Services
  module BooksMigration
    # Run once, right after the final data_migration:all (spec §5). Books and
    # authors start from the last legacy-origin id here, which is what :all just
    # loaded. book_identifiers starts from legacy's current max, because legacy
    # keeps adding identifiers to books that already exist.
    class SyncInit
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(legacy: LegacySource.new)
        new(legacy: legacy).call
      end

      def initialize(legacy:)
        @legacy = legacy
      end

      def call
        if LegacySyncWatermark.exists?
          return Result.new(
            success?: false,
            data: LegacySyncWatermark.pluck(:key, :value).to_h,
            errors: ["sync watermarks already exist; data_migration:sync_init runs once"]
          )
        end

        values = {
          "books" => Services::BooksMigration.max_legacy_origin_id("books_books"),
          "authors" => Services::BooksMigration.max_legacy_origin_id("books_authors"),
          "book_identifiers" => @legacy.max_book_identifier_id
        }
        LegacySyncWatermark.transaction do
          values.each { |key, value| LegacySyncWatermark.create!(key: key, value: value) }
        end
        Result.new(success?: true, data: values, errors: [])
      end
    end
  end
end
