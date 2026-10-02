# frozen_string_literal: true

module Books
  module OpenLibrary
    # A resolved Open Library author record. Same two-constructor shape as
    # Work, for the same reason: `from_response` unwraps the singular
    # endpoint's envelope, `from_record` takes the bare record (used by
    # `#authors_batch`, one requested key at a time).
    Author = Data.define(
      :key, :source, :name, :alternate_names, :birth_year, :death_year,
      :redirected_from, :source_version
    ) do
      def self.from_response(envelope)
        from_record(envelope["data"], source_version: envelope["source_version"])
      end

      def self.from_record(record, source_version:)
        new(
          key: record.dig("key", "key"),
          source: record.dig("key", "source"),
          name: record["name"],
          alternate_names: record["alternate_names"] || [],
          birth_year: record["birth_year"],
          death_year: record["death_year"],
          redirected_from: (record["redirected_from"] || []).map { |key| key["key"] },
          source_version: source_version&.deep_symbolize_keys
        )
      end
    end
  end
end
