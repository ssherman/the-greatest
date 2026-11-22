# frozen_string_literal: true

module Services
  module Lists
    # The penalties that actually lowered a list's weight on one configuration:
    # the ids recorded in its ranked list's calculated_weight_details, the same
    # set the weight breakdown on the web renders. Ordered by category then name.
    class PenaltiesInEffect
      def self.call(ranked_list)
        ids = Array(ranked_list&.calculated_weight_details&.dig("penalties")).filter_map { |entry| entry["penalty_id"] }
        return [] if ids.empty?

        ::Penalty.where(id: ids).order(:category, :name).to_a
      end
    end
  end
end
