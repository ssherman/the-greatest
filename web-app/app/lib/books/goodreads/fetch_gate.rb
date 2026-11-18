# frozen_string_literal: true

module Books
  module Goodreads
    # When the next Goodreads page fetch may start (Goodreads import spec §6,
    # "Politeness"): Books::FetchGate keyed to the Goodreads line and limited
    # by config.x.goodreads. Only the goodreads_fetch capsule, one job at a
    # time, reserves.
    class FetchGate < Books::FetchGate
      KEY = "goodreads:fetch"

      def initialize(redis: nil, config: nil)
        super(key: KEY, config: config || Rails.application.config.x.goodreads, label: "Goodreads", redis: redis)
      end
    end
  end
end
