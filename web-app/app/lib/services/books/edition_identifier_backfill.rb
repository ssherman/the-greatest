# frozen_string_literal: true

module Services
  module Books
    # One-time lift of edition-level identifiers out of the legacy Amazon blob.
    #
    # Every books_editions row came from Amazon via the legacy application, which
    # stored the whole PA-API 5.0 response under metadata.amazon in PascalCase.
    # The books migration deliberately folded edition ISBNs and ASINs UP to the
    # work level, so there are no edition-level identifiers to dedupe on today.
    # Enrichment that ran before this backfill would duplicate every one of them.
    #
    # Idempotent: insert_all with unique_by the identifiers lookup index, so a
    # re-run inserts nothing.
    class EditionIdentifierBackfill
      LOOKUP_INDEX = :index_identifiers_on_lookup_unique

      def self.call(batch_size: 1_000)
        new(batch_size: batch_size).call
      end

      def initialize(batch_size: 1_000)
        @batch_size = batch_size
      end

      def call
        written = 0

        scope.find_in_batches(batch_size: @batch_size) do |editions|
          rows = editions.flat_map { |edition| rows_for(edition) }
          next if rows.empty?

          rows.uniq! { |row| [row[:identifiable_type], row[:identifier_type], row[:value], row[:identifiable_id]] }
          Identifier.insert_all(rows, unique_by: LOOKUP_INDEX)

          written += rows.size
          Rails.logger.info "EditionIdentifierBackfill: #{written} rows attempted"
        end

        written
      end

      private

      def scope
        ::Books::Edition.where("metadata -> 'amazon' IS NOT NULL")
      end

      def rows_for(edition)
        amazon = edition.metadata["amazon"]
        return [] unless amazon.is_a?(Hash)

        now = Time.current
        rows = []

        asin = amazon["ASIN"].presence
        rows << row(edition, :books_edition_asin, asin, now) if asin

        external_ids = amazon.dig("ItemInfo", "ExternalIds") || {}

        Array(external_ids.dig("ISBNs", "DisplayValues")).each do |raw|
          value = raw.to_s
          type = case value.length
          when 13 then :books_edition_isbn13
          when 10 then :books_edition_isbn10
          end
          rows << row(edition, type, value, now) if type
        end

        Array(external_ids.dig("EANs", "DisplayValues")).each do |raw|
          value = raw.to_s
          rows << row(edition, :books_edition_ean13, value, now) if value.length == 13
        end

        rows
      end

      def row(edition, identifier_type, value, now)
        {
          identifiable_type: "Books::Edition",
          identifiable_id: edition.id,
          identifier_type: Identifier.identifier_types[identifier_type],
          value: value,
          created_at: now,
          updated_at: now
        }
      end
    end
  end
end
