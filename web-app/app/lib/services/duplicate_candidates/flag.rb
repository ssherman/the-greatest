# frozen_string_literal: true

module Services
  module DuplicateCandidates
    # Raise (or re-raise) a suspected pair. Ids may arrive in any order. A
    # pair a human dismissed is never reopened, and a merged one is left
    # alone; a pending one gains an occurrence and any new evidence.
    class Flag
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(item_type:, ids:, source:, evidence: {}, match_decision: nil)
        new(item_type: item_type, ids: ids, source: source, evidence: evidence, match_decision: match_decision).call
      end

      def initialize(item_type:, ids:, source:, evidence: {}, match_decision: nil)
        @item_type = item_type
        @ids = ids
        @source = source
        @evidence = evidence
        @match_decision = match_decision
      end

      # data is the DuplicateCandidate row, or nil when both ids are the same record.
      def call
        a, b = @ids.map(&:to_i).minmax
        return Result.new(success?: true, data: nil, errors: []) if a == b

        row = ::DuplicateCandidate.find_or_initialize_by(item_type: @item_type, item_a_id: a, item_b_id: b)
        if row.persisted?
          return Result.new(success?: true, data: row, errors: []) unless row.pending?

          row.occurrences += 1
          row.evidence = merge_evidence(row.evidence, @evidence)
          row.save!
          return Result.new(success?: true, data: row, errors: [])
        end

        row.assign_attributes(source: @source, evidence: @evidence.deep_stringify_keys, match_decision: @match_decision, status: :pending, occurrences: 1)
        row.save!
        Result.new(success?: true, data: row, errors: [])
      end

      private

      def merge_evidence(existing, incoming)
        existing.merge(incoming.deep_stringify_keys) do |_key, old, new|
          (old.is_a?(Array) && new.is_a?(Array)) ? (old | new) : new
        end
      end
    end
  end
end
