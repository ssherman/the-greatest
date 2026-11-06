# frozen_string_literal: true

module DataImporters
  module Sources
    # Postgres lookup of the query's identifier values, in the domain's
    # priority order, through the (identifiable_type, value) index. Two
    # records carrying the same value both come back: the unique index on
    # identifiers includes identifiable_id, so it allows that, and the
    # finder wants to see the collision. Never marks a candidate decisive;
    # whether an identifier hit can be trusted is the finder's corroboration
    # call.
    #
    # sources: only rows whose Identifier#source is in this list (strings, as
    # Identifier.sources keys) count. nil, the default, means every row.
    class Identifiers
      def initialize(model_class:, lookups:, sources: nil)
        @model_class = model_class
        @lookups = lookups
        @sources = sources
      end

      def name
        :identifier
      end

      def call
        @lookups.flat_map do |identifier_type, value|
          scope = ::Identifier
            .includes(:identifiable)
            .where(identifiable_type: @model_class.name, identifier_type: identifier_type, value: value)
          scope = scope.where(source: @sources) if @sources
          scope
            .order(:identifiable_id)
            .map do |identifier|
              Candidate.new(
                record: identifier.identifiable,
                sources: [:identifier],
                evidence: {matched_identifier: {type: identifier_type.to_s, value: value}}
              )
            end
        end
      end
    end
  end
end
