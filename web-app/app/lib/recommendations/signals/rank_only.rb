# frozen_string_literal: true

module Recommendations
  module Signals
    # The candidate pool in global-rank order: the engine's fallback when the
    # profile is empty, and the harness's rank baseline. Never fused with the
    # personalized signals -- the rank prior inside Fusion is how rank enters
    # a personalized page.
    class RankOnly < Base
      def weight(_positive_count)
        1.0
      end

      def call(profile:, interactions:, criteria:, excluded_ids:, size:)
        adapter.rank_ordered_candidates(criteria: criteria, excluded_ids: excluded_ids, size: size)
      end
    end
  end
end
