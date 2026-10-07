# frozen_string_literal: true

module Recommendations
  module Reranker
    # A sequel is recommended only to someone who has the preceding book as a
    # favorite, read, reading, or rated (spec §8.1). Want-to-read does not unlock
    # it: intent is not experience. Dropping the sequel leaves the series opener
    # in place when it is itself a candidate.
    module SeriesRule
      UNLOCKING_KINDS = %i[favorite read reading].freeze

      def self.call(candidates, facts:, interactions:)
        unlocked = interactions.select { |i| UNLOCKING_KINDS.include?(i.kind) || !i.rating.nil? }
          .map(&:item_id).to_set

        candidates.select do |candidate|
          predecessor = facts[candidate.item_id]&.series_predecessor_id
          predecessor.nil? || unlocked.include?(predecessor)
        end
      end
    end
  end
end
