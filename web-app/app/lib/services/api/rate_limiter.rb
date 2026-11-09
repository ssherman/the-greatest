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

      def self.hit_ip(window, ip, now: Time.current) = new(now: now).hit_ip(window, ip)

      def self.peek_ip(window, ip, now: Time.current) = new(now: now).peek_ip(window, ip)

      def self.connector_range?(ip) = new.connector_range?(ip)

      # The IP windows, each with its per-IP limit's config key. Connector
      # ranges take their budget from config.connector_range_per_minute[window].
      IP_WINDOWS = {
        unauthenticated: :unauthenticated_per_minute,
        oauth_register: :oauth_register_per_minute,
        oauth_token: :oauth_token_per_minute
      }.freeze

      # Parsed CIDRs, keyed by the config hash they came from, so each set of
      # ranges is parsed once per process rather than once per request.
      PARSED_RANGES = Concurrent::Map.new
      private_constant :PARSED_RANGES

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

      def hit_unauthenticated(ip) = hit_ip(:unauthenticated, ip)

      # Reads the IP window without counting, so a request from an address that
      # is already over the limit can be refused before the database is consulted.
      def peek_unauthenticated(ip) = peek_ip(:unauthenticated, ip)

      # Counts one request from `ip` against `window` (:unauthenticated,
      # :oauth_register or :oauth_token). An address inside a connector egress
      # range shares that range's counter and budget, because a hosted connector
      # presents thousands of users from a handful of addresses; any other
      # address gets its own per-IP counter.
      def hit_ip(window, ip)
        subject, limit = ip_budget(window, ip)
        Verdict.new(minute: increment(minute_key(subject), limit, minute_end), day: nil)
      end

      def peek_ip(window, ip)
        subject, limit = ip_budget(window, ip)
        count = store.read(minute_key(subject), raw: true).to_i

        Verdict.new(
          minute: Window.new(limit: limit, remaining: [limit - count, 0].max, reset_at: minute_end, exceeded: count >= limit),
          day: nil
        )
      end

      # True when `ip` is inside a connector egress range, so its IP windows are
      # a counter shared with every other caller of that connector.
      def connector_range?(ip) = connector_range_for(ip).present?

      private

      attr_reader :now, :store, :config

      # [counter subject, limit]. The :unauthenticated per-IP subject predates
      # the other windows and keeps its original key.
      def ip_budget(window, ip)
        per_ip_limit = config.public_send(IP_WINDOWS.fetch(window))

        if (range = connector_range_for(ip))
          ["#{window}:range:#{range}", config.connector_range_per_minute.fetch(window)]
        elsif window == :unauthenticated
          ["anon:#{subject_address(ip)}", per_ip_limit]
        else
          ["#{window}:ip:#{subject_address(ip)}", per_ip_limit]
        end
      end

      # One host can rotate through a whole /64, so a per-address window would
      # not bind an IPv6 caller: count the /64 instead. An IPv4-mapped address
      # counts as its IPv4 address; an unparsable one as its own string.
      def subject_address(ip)
        address = IPAddr.new(ip.to_s)
        return address.native.to_s if address.ipv4_mapped?

        address.ipv6? ? "#{address.mask(64)}/64" : address.to_s
      rescue IPAddr::Error
        ip.to_s
      end

      def connector_range_for(ip)
        ranges = config.connector_egress_ranges
        return if ranges.blank?

        address = IPAddr.new(ip.to_s)
        address = address.native if address.ipv4_mapped?
        parsed_ranges(ranges).find { |_name, nets| nets.any? { |net| net.include?(address) } }&.first
      rescue IPAddr::Error
        nil
      end

      def parsed_ranges(ranges)
        PARSED_RANGES.compute_if_absent(ranges) do
          ranges.transform_values { |cidrs| cidrs.map { |cidr| IPAddr.new(cidr) }.freeze }.freeze
        end
      end

      def minute_start = Time.at(now.to_i - (now.to_i % 60)).utc

      def minute_end = minute_start + 60

      def day_end = now.utc.beginning_of_day + 1.day

      def minute_key(subject) = "api:rl:#{subject}:m:#{minute_start.to_i}"

      def day_key(subject) = "api:rl:#{subject}:d:#{now.utc.to_date.iso8601}"

      # increment creates the key with the expiry when it is new, and returns the
      # new count. One second of slack so a key never outlives its window by
      # less than the clock granularity.
      def increment(key, limit, reset_at)
        # ActiveSupport::Cache::RedisCacheStore#increment runs inside Rails' failsafe,
        # which swallows Redis::BaseError/ConnectionPool::Error and returns nil on a
        # Redis outage. Treat that as zero and fail OPEN, matching the rest of the app's
        # limiters (the `rate_limit` macro guards `if count && count > to`, and
        # peek_unauthenticated above already `.to_i`s a nil read) -- a Redis outage must
        # not take the API down.
        count = store.increment(key, 1, expires_in: (reset_at - now).ceil + 1) || 0
        Window.new(limit: limit, remaining: [limit - count, 0].max, reset_at: reset_at, exceeded: count > limit)
      end
    end
  end
end
