# frozen_string_literal: true

module Services
  module Books
    module SeriesEdits
      # Serializes claims on a Goodreads series id. The identifiers unique index includes
      # identifiable_id, so the database can't stop two series storing the same id; this
      # transaction-scoped advisory lock does. Call inside a transaction, then re-check the
      # holder (holder_of) under the lock before writing.
      module GoodreadsIdLock
        def self.acquire(value)
          key = "books_series_goodreads_id:#{value}"
          ::Books::Series.connection.execute(
            ::Books::Series.sanitize_sql_array(["SELECT pg_advisory_xact_lock(hashtext(?))", key])
          )
        end

        def self.holder_of(value)
          ::Identifier.find_by(identifier_type: :books_series_goodreads_id, value: value.to_s)
        end
      end
    end
  end
end
