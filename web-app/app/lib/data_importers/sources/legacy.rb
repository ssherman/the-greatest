# frozen_string_literal: true

module DataImporters
  module Sources
    # Increment 1 only: a domain finder's pre-redesign lookup, wrapped as the
    # single, decisive source so the pipeline runs for real while behaviour
    # stays exactly what it was. Each domain's increment replaces it with the
    # real sources and deletes the lookup it wraps.
    class Legacy
      def initialize(&lookup)
        @lookup = lookup
      end

      def name
        :legacy
      end

      def call
        record = @lookup.call
        return [] unless record

        [Candidate.new(record: record, sources: [:legacy], decisive: true)]
      end
    end
  end
end
