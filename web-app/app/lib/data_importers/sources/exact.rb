# frozen_string_literal: true

module DataImporters
  module Sources
    # One Postgres query the finder builds (normalized title or name
    # equality, joined to a creator when the query has one). Kept alongside
    # OpenSearch because the search index is written by a queued job, so a
    # record created seconds ago is not yet searchable.
    class Exact
      def initialize(scope:, limit: 5)
        @scope = scope
        @limit = limit
      end

      def name
        :exact
      end

      def call
        @scope.limit(@limit).map { |record| Candidate.new(record: record, sources: [:exact]) }
      end
    end
  end
end
