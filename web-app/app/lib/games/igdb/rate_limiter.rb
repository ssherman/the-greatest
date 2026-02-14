# frozen_string_literal: true

module Games
  module Igdb
    # IGDB-specific rate limiter that delegates to the generic DistributedRateLimiter.
    # Enforces IGDB's 4 requests per second limit across all processes.
    class RateLimiter
      REQUESTS_PER_SECOND = 4

      def initialize(mode: :blocking)
        @limiter = ::DistributedRateLimiter.new(
          key: "igdb:api",
          limit: REQUESTS_PER_SECOND,
          window: 1.0,
          mode: mode
        )
      end

      # Wait until a rate limit slot is available, then consume it.
      # Preserves the original API for BaseClient compatibility.
      def wait!
        @limiter.acquire!
      end
    end
  end
end
