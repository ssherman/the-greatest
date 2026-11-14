# frozen_string_literal: true

module Services
  module Books
    module RepairVerdicts
      # The Goodreads import rows a verdict's finding came from: the payload's [legacy import id, row number] pairs,
      # resolved to rows in two queries. Shared by the admin page and the admin API.
      class SourceRows
        def self.pairs(verdict) = Array(verdict.payload["rows"])

        # Rows (with their import and edition loaded) for the first `limit` pairs, or all of them. Pairs that name
        # no row are dropped.
        def self.call(verdict, limit: nil)
          pairs = self.pairs(verdict)
          pairs = pairs.first(limit) if limit
          return [] if pairs.empty?

          imports = ::Books::GoodreadsImport.where(legacy_import_id: pairs.map(&:first)).index_by(&:legacy_import_id)
          wanted = pairs.filter_map { |legacy_id, number| [imports[legacy_id].id, number] if imports[legacy_id] }
          return [] if wanted.empty?

          rows = ::Books::GoodreadsImportRow.where(import_id: wanted.map(&:first).uniq, row_number: wanted.map(&:last).uniq)
            .includes(:import, :goodreads_edition).index_by { |row| [row.import_id, row.row_number] }
          wanted.filter_map { |key| rows[key] }
        end
      end
    end
  end
end
