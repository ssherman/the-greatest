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
        ids = @ids.compact.map(&:to_i)
        return Result.new(success?: false, data: nil, errors: ["two ids are required, got #{@ids.inspect}"]) unless ids.size == 2

        a, b = ids.minmax
        return Result.new(success?: true, data: nil, errors: []) if a == b

        attempts = 0
        begin
          attempts += 1
          Result.new(success?: true, data: upsert(a, b), errors: [])
        rescue ActiveRecord::RecordNotUnique
          # Two finders raised the same pair at once; the second insert lost
          # the race, and the row it wanted now exists.
          raise if attempts > 1

          retry
        end
      end

      private

      def upsert(a, b)
        row = ::DuplicateCandidate.find_or_initialize_by(item_type: @item_type, item_a_id: a, item_b_id: b)
        if row.persisted?
          return row unless row.pending?

          row.occurrences += 1
          row.evidence = merge_evidence(row.evidence, @evidence)
          row.save!
          return row
        end

        row.assign_attributes(source: @source, evidence: @evidence.deep_stringify_keys, match_decision: @match_decision, status: :pending, occurrences: 1)
        row.save!
        row
      end

      def merge_evidence(existing, incoming)
        existing.merge(incoming.deep_stringify_keys) do |_key, old, new|
          (old.is_a?(Array) && new.is_a?(Array)) ? (old | new) : new
        end
      end
    end
  end
end
