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
    class Identifiers
      def initialize(model_class:, lookups:)
        @model_class = model_class
        @lookups = lookups
      end

      def name
        :identifier
      end

      def call
        @lookups.flat_map do |identifier_type, value|
          ::Identifier
            .includes(:identifiable)
            .where(identifiable_type: @model_class.name, identifier_type: identifier_type, value: value)
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
