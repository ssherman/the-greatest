# frozen_string_literal: true

module Books
  module OpenLibrary
    # A resolved Open Library work record.
    #
    # Two constructors because the same WorkRecord shape shows up two ways in
    # the wire contract: `from_response` unwraps the `{source_version, data}`
    # envelope every singular retrieval endpoint returns, while `from_record`
    # takes the bare record hash directly -- what a `/resolve` candidate's
    # `record` is, and what `#works_batch` yields per requested key (one
    # envelope, many records, so there is no per-record envelope to unwrap).
    Work = Data.define(
      :key, :source, :title, :subtitle, :description,
      :author_keys, :author_names, :subjects,
      :year_evidence, :popularity, :redirected_from, :source_version
    ) do
      def self.from_response(envelope)
        from_record(envelope["data"], source_version: envelope["source_version"])
      end

      def self.from_record(record, source_version:)
        authors = record["authors"] || []

        new(
          key: record.dig("key", "key"),
          source: record.dig("key", "source"),
          title: record["title"],
          subtitle: record["subtitle"],
          description: record["description"],
          author_keys: authors.map { |author| author.dig("key", "key") },
          author_names: authors.map { |author| author["name"] },
          subjects: record["subjects"] || [],
          year_evidence: record["year_evidence"]&.deep_symbolize_keys,
          popularity: record["popularity"]&.deep_symbolize_keys,
          redirected_from: (record["redirected_from"] || []).map { |key| key["key"] },
          source_version: source_version&.deep_symbolize_keys
        )
      end
    end
  end
end
