# frozen_string_literal: true

module Services
  module Api
    # Fixed-window counters for the public API on the same store the site's
    # `rate_limit` macros use (config.x.rate_limit_store: Redis in production,
    # a real MemoryStore in test -- see config/initializers/rate_limit_store.rb
    # for why a null store would make every limit test pass vacuously).
    #
    # Keyed on the USER, never the token: minting more tokens must not multiply
    # quota. Two windows per tier -- a calendar minute and a UTC calendar day --
    # plus a per-IP minute window for unauthenticated failures.
    #
    # Not DistributedRateLimiter: that is a blocking sliding-window limiter for
    # OUTBOUND calls to third-party APIs. This one answers with the numbers the
    # X-RateLimit-* headers need.
    class RateLimiter
      Window = Struct.new(:limit, :remaining, :reset_at, :exceeded, keyword_init: true) do
        def exceeded? = exceeded
      end

      Verdict = Struct.new(:minute, :day, keyword_init: true) do
        def windows = [minute, day].compact

        def exceeded? = windows.any?(&:exceeded?)

        # Seconds until the earliest exceeded window resets -- what Retry-After
        # carries. nil when nothing is exceeded.
        def retry_after(now = Time.current)
          reset = windows.select(&:exceeded?).map(&:reset_at).min
          reset && [(reset - now).ceil, 1].max
        end
      end

      def self.hit(principal, now: Time.current) = new(now: now).hit(principal)

      def self.hit_unauthenticated(ip, now: Time.current) = new(now: now).hit_unauthenticated(ip)

      def self.peek_unauthenticated(ip, now: Time.current) = new(now: now).peek_unauthenticated(ip)

      def initialize(now: Time.current, store: Rails.application.config.x.rate_limit_store, config: Rails.application.config.x.api)
        @now = now
        @store = store
        @config = config
      end

      # Counts this request against both of the principal's windows. A request
      # that exceeds a window still counts: hammering a 429 does not help.
      def hit(principal)
        limits = config.rate_limits.fetch(principal.tier)
        subject = "u:#{principal.user.id}"

        Verdict.new(
          minute: increment(minute_key(subject), limits.fetch(:per_minute), minute_end),
          day: increment(day_key(subject), limits.fetch(:per_day), day_end)
        )
      end

      def hit_unauthenticated(ip)
        Verdict.new(minute: increment(minute_key("anon:#{ip}"), config.unauthenticated_per_minute, minute_end), day: nil)
      end

      # Reads the IP window without counting, so a request from an address that
      # is already over the limit can be refused before the database is consulted.
      def peek_unauthenticated(ip)
        limit = config.unauthenticated_per_minute
        count = store.read(minute_key("anon:#{ip}"), raw: true).to_i

        Verdict.new(
          minute: Window.new(limit: limit, remaining: [limit - count, 0].max, reset_at: minute_end, exceeded: count >= limit),
          day: nil
        )
      end

      private

      attr_reader :now, :store, :config

      def minute_start = Time.at(now.to_i - (now.to_i % 60)).utc

      def minute_end = minute_start + 60

      def day_end = now.utc.beginning_of_day + 1.day

      def minute_key(subject) = "api:rl:#{subject}:m:#{minute_start.to_i}"

      def day_key(subject) = "api:rl:#{subject}:d:#{now.utc.to_date.iso8601}"

      # increment creates the key with the expiry when it is new, and returns the
      # new count. One second of slack so a key never outlives its window by
      # less than the clock granularity.
      def increment(key, limit, reset_at)
        count = store.increment(key, 1, expires_in: (reset_at - now).ceil + 1)
        Window.new(limit: limit, remaining: [limit - count, 0].max, reset_at: reset_at, exceeded: count > limit)
      end
    end
  end
end
