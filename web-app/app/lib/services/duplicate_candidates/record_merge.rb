# frozen_string_literal: true

module Services
  module DuplicateCandidates
    # Called by every merger inside its transaction, before the source row
    # is destroyed. The (source, target) pair itself becomes `merged`; every
    # other PENDING pair naming the source is re-keyed onto the target unless
    # a row for that pair already exists, in which case the stale one is
    # dropped. Decisions whose record was the source now point at the target.
    class RecordMerge
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(item_type:, source_id:, target_id:)
        new(item_type: item_type, source_id: source_id, target_id: target_id).call
      end

      def initialize(item_type:, source_id:, target_id:)
        @item_type = item_type
        @source_id = source_id
        @target_id = target_id
      end

      def call
        mark_pair_merged
        rekey_pending_pairs
        repoint_decisions
        Result.new(success?: true, data: nil, errors: [])
      end

      private

      def mark_pair_merged
        a, b = [@source_id, @target_id].minmax
        ::DuplicateCandidate.where(item_type: @item_type, item_a_id: a, item_b_id: b)
          .update_all(status: ::DuplicateCandidate.statuses[:merged], resolved_at: Time.current, updated_at: Time.current)
      end

      def rekey_pending_pairs
        ::DuplicateCandidate.where(item_type: @item_type, status: ::DuplicateCandidate.statuses[:pending])
          .where("item_a_id = :id OR item_b_id = :id", id: @source_id)
          .find_each do |row|
            other = (row.item_a_id == @source_id) ? row.item_b_id : row.item_a_id
            next row.destroy! if other == @target_id

            new_a, new_b = [other, @target_id].minmax
            if ::DuplicateCandidate.exists?(item_type: @item_type, item_a_id: new_a, item_b_id: new_b)
              row.destroy!
            else
              row.update!(item_a_id: new_a, item_b_id: new_b)
            end
          end
      end

      def repoint_decisions
        ::MatchDecision.where(record_type: @item_type, record_id: @source_id)
          .update_all(record_id: @target_id, updated_at: Time.current)
      end
    end
  end
end
