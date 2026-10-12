# frozen_string_literal: true

module Services
  module CategoryCleanup
    # A propose stage prints its estimated cost and refuses to start above
    # max_unforced_cost unless forced (spec §7).
    class CostGuard
      class TooExpensive < StandardError; end

      def self.check!(calls:, force: false)
        config = Rails.configuration.x.categories_cleanup
        estimate = calls * config.estimated_cost_per_call
        if estimate > config.max_unforced_cost && !force
          raise TooExpensive, format("Estimated $%.2f for %d calls is over $%d; rerun with FORCE=1", estimate, calls, config.max_unforced_cost)
        end

        estimate
      end
    end
  end
end
