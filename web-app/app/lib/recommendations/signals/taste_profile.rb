# frozen_string_literal: true

module Recommendations
  module Signals
    class TasteProfile < Base
      def weight(_positive_count)
        config[:taste_weight].to_f
      end

      def call(profile:, interactions:, criteria:, excluded_ids:, size:)
        return [] if profile.empty?

        adapter.search_candidates(profile: profile, criteria: criteria, excluded_ids: excluded_ids, size: size)
      end
    end
  end
end
