# frozen_string_literal: true

module Viaf
  # Paces requests to stay under VIAF's Cloudflare WAF, which trips at roughly
  # 5-8 requests in rapid succession and then blocks the IP for minutes.
  # Two requests per minute (~30s apart) is deliberately more conservative than
  # the 25s spacing that was verified safe. At this pace the ~1,000/day
  # application budget is reached well before a day is out (2 req/min is
  # 2,880/day), so the daily budget, not this pace, is the binding constraint
  # (see Viaf::Schedule::SLOT_SECONDS).
  class RateLimiter
    REQUESTS_PER_WINDOW = 2
    WINDOW_SECONDS = 60.0

    def initialize(mode: :blocking)
      @limiter = ::DistributedRateLimiter.new(
        key: "viaf:api",
        limit: REQUESTS_PER_WINDOW,
        window: WINDOW_SECONDS,
        mode: mode
      )
    end

    def wait!
      @limiter.acquire!
    end
  end
end
