# frozen_string_literal: true

module Services
  module Books
    module RepairVerdicts
      # The Goodreads import rows a verdict's finding came from, resolved in at most two queries. Shared by the admin
      # page and the admin API. Verdicts name their rows in one of two forms:
      #
      # - Replay findings: payload["rows"], [legacy import id, row number] pairs (the old site's import ids).
      # - Re-import verdicts: our own books_goodreads_imports.id with a row number. A reimport_row names one row
      #   (payload["import_id"], payload["row_number"]); a reimport_mixed lists its book's rows in payload["row_keys"].
      #
      # A reimport_guess has no row: it exists because no CSV row explains the reader's entry.
      class SourceRows
        def self.pairs(verdict)
          payload = verdict.payload
          if verdict.reimport_row?
            key = [payload["import_id"], payload["row_number"]]
            key.all? ? [key] : []
          elsif verdict.reimport_mixed?
            Array(payload["row_keys"])
          else
            Array(payload["rows"])
          end
        end

        # Rows (with their import and edition loaded) for the first `limit` pairs, or all of them. Pairs that name
        # no row are dropped.
        def self.call(verdict, limit: nil)
          pairs = self.pairs(verdict)
          pairs = pairs.first(limit) if limit
          return [] if pairs.empty?

          wanted = own_ids?(verdict) ? pairs : legacy_to_own(pairs)
          return [] if wanted.empty?

          rows = ::Books::GoodreadsImportRow.where(import_id: wanted.map(&:first).uniq, row_number: wanted.map(&:last).uniq)
            .includes(:import, :goodreads_edition).index_by { |row| [row.import_id, row.row_number] }
          wanted.filter_map { |key| rows[key] }
        end

        def self.own_ids?(verdict) = verdict.reimport_row? || verdict.reimport_mixed?

        def self.legacy_to_own(pairs)
          imports = ::Books::GoodreadsImport.where(legacy_import_id: pairs.map(&:first)).index_by(&:legacy_import_id)
          pairs.filter_map { |legacy_id, number| [imports[legacy_id].id, number] if imports[legacy_id] }
        end

        private_class_method :own_ids?, :legacy_to_own
      end
    end
  end
end
