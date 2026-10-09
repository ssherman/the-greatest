module Services
  module BooksMigration
    # Run once, right after the final data_migration:all (spec §5). Books and
    # authors start from the last legacy-origin id here, which is what :all just
    # loaded. book_identifiers starts from legacy's current max, because legacy
    # keeps adding identifiers to books that already exist. The final :all runs for
    # hours after its identifier pass, so pass book_identifiers: legacy's max taken
    # before that :all started; a lower watermark only re-reads rows the
    # find-or-create migrator already has.
    #
    # Redirect rows for records that exist here are removed: the weekly :all ignores
    # redirects, so it brings back what was deleted or merged before sync_init.
    class SyncInit
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)
      MODELS = {"Books::Book" => ::Books::Book, "Books::Author" => ::Books::Author}.freeze

      def self.call(legacy: LegacySource.new, book_identifiers: nil)
        new(legacy: legacy, book_identifiers: book_identifiers).call
      end

      def initialize(legacy:, book_identifiers: nil)
        @legacy = legacy
        @book_identifiers = book_identifiers
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
          "book_identifiers" => @book_identifiers || @legacy.max_book_identifier_id
        }
        removed = 0
        LegacySyncWatermark.transaction do
          values.each { |key, value| LegacySyncWatermark.create!(key: key, value: value) }
          removed = MODELS.sum do |item_type, model|
            RecordRedirect.where(item_type: item_type, from_id: model.select(:id)).delete_all
          end
        end
        Result.new(success?: true, data: values.merge("stale_redirects_removed" => removed), errors: [])
      end
    end
  end
end
