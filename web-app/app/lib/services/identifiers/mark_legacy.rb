# frozen_string_literal: true

module Services
  module Identifiers
    # Identifier provenance spec, section 1: once, after the source column
    # ships. Every books-domain identifier with no source came from legacy
    # (or from code acting on legacy's choices), so it becomes legacy. Then
    # the keys the OL key backfill wrote or confirmed, if it ran first,
    # become open_library. Batched by id; only null rows are marked, so a
    # re-run marks nothing new. Music and games rows are never touched.
    class MarkLegacy
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(batch_size: 10_000)
        new(batch_size).call
      end

      def initialize(batch_size)
        @batch_size = batch_size
      end

      def call
        legacy_by_type = ::Identifier::BOOKS_TYPES.to_h { |type| [type, mark_legacy(type)] }.select { |_type, count| count.positive? }
        open_library = relabel_backfill_keys
        Result.new(success?: true, errors: [],
          data: {legacy: legacy_by_type.values.sum, legacy_by_type: legacy_by_type, open_library: open_library})
      end

      private

      def mark_legacy(type)
        marked = 0
        ::Identifier.where(identifiable_type: type, source: nil).in_batches(of: @batch_size) do |batch|
          marked += batch.update_all(source: ::Identifier.sources[:legacy], updated_at: Time.current)
        end
        marked
      end

      def relabel_backfill_keys
        relabelled = 0
        ::Books::Verification.where(work_outcome: ::Books::Verification::KEYED_OUTCOMES).find_each do |row|
          relabelled += relabel("Books::Book", row.book_id, "books_work_openlibrary_id", [row.new_key])
          relabelled += relabel("Books::Book", row.book_id, "books_work_openlibrary_duplicate_id", row.duplicate_keys)
          Array(row.author_changes["added"]).each do |author_id, key|
            relabelled += relabel("Books::Author", author_id, "books_author_openlibrary_id", [key])
          end
        end
        relabelled
      end

      def relabel(type, id, identifier_type, values)
        values = Array(values).compact
        return 0 if values.empty?

        ::Identifier.where(identifiable_type: type, identifiable_id: id, identifier_type: identifier_type, value: values)
          .where.not(source: ::Identifier.sources[:open_library])
          .update_all(source: ::Identifier.sources[:open_library], updated_at: Time.current)
      end
    end
  end
end
