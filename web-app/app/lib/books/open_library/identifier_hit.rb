# frozen_string_literal: true

module Books
  module OpenLibrary
    # One work matched by `GET /identifiers/{type}/{value}`. Always served as
    # part of a list, even for an identifier that maps to exactly one work --
    # `Client#identifier` never unwraps that down to a bare hit.
    IdentifierHit = Data.define(:work_key, :source, :redirected_from, :edition_keys, :id_type, :value) do
      def self.from_record(record)
        new(
          work_key: record.dig("work", "key"),
          source: record.dig("work", "source"),
          redirected_from: (record["redirected_from"] || []).map { |key| key["key"] },
          edition_keys: (record["editions"] || []).map { |key| key["key"] },
          id_type: record["id_type"],
          value: record["value"]
        )
      end
    end
  end
end
