require "test_helper"

module Services
  module Api
    class RateLimiterTest < ActiveSupport::TestCase
      NOW = Time.utc(2026, 9, 13, 10, 30, 15)

      setup do
        @store = ActiveSupport::Cache::MemoryStore.new
        @config = ActiveSupport::OrderedOptions.new
        @config.rate_limits = {member: {per_minute: 3, per_day: 5}, system: {per_minute: 10, per_day: 20}}
        @config.unauthenticated_per_minute = 2
        @member = ::Api::Principal.new(user: users(:regular_user), token: nil, scopes: [], tier: :member)
        @system = ::Api::Principal.new(user: users(:agent_runner_service_account), token: nil, scopes: [], tier: :system)
      end

      def limiter(now: NOW) = RateLimiter.new(now: now, store: @store, config: @config)

      test "the first hit reports the tier's limits with one consumed" do
        verdict = limiter.hit(@member)

        assert_equal 3, verdict.minute.limit
        assert_equal 2, verdict.minute.remaining
        assert_equal Time.utc(2026, 9, 13, 10, 31, 0), verdict.minute.reset_at
        assert_equal 5, verdict.day.limit
        assert_equal 4, verdict.day.remaining
        assert_equal Time.utc(2026, 9, 14, 0, 0, 0), verdict.day.reset_at
        refute verdict.exceeded?
        assert_nil verdict.retry_after(NOW)
      end

      test "the request that crosses the minute limit is exceeded and still counts" do
        3.times { limiter.hit(@member) }

        verdict = limiter.hit(@member)

        assert verdict.minute.exceeded?
        assert verdict.exceeded?
        assert_equal 0, verdict.minute.remaining
        assert_equal 45, verdict.retry_after(NOW)

        again = limiter.hit(@member)
        assert again.exceeded?
        assert_equal 0, again.minute.remaining
      end

      test "a new minute resets the minute window but not the day" do
        3.times { limiter.hit(@member) }
        assert limiter.hit(@member).exceeded?

        verdict = limiter(now: NOW + 60).hit(@member)

        refute verdict.minute.exceeded?
        assert_equal 2, verdict.minute.remaining
        assert_equal 0, verdict.day.remaining
        refute verdict.day.exceeded?, "the fifth of five is at the limit, not over it"

        assert limiter(now: NOW + 60).hit(@member).day.exceeded?
      end

      test "the day window resets at midnight UTC" do
        5.times { limiter.hit(@member) }

        verdict = limiter(now: Time.utc(2026, 9, 14, 0, 0, 1)).hit(@member)

        assert_equal 4, verdict.day.remaining
        assert_equal Time.utc(2026, 9, 15), verdict.day.reset_at
      end

      test "retry_after is the seconds until the earliest exceeded window resets" do
        5.times { limiter.hit(@member) }
        verdict = limiter(now: NOW + 120).hit(@member)

        assert verdict.day.exceeded?
        refute verdict.minute.exceeded?
        assert_equal (Time.utc(2026, 9, 14) - (NOW + 120)).to_i, verdict.retry_after(NOW + 120)
      end

      test "windows are keyed on the user, so two principals do not share a bucket" do
        3.times { limiter.hit(@member) }
        other = ::Api::Principal.new(user: users(:editor_user), token: nil, scopes: [], tier: :member)

        refute limiter.hit(other).exceeded?
      end

      test "the system tier reads its own limits" do
        verdict = limiter.hit(@system)

        assert_equal 10, verdict.minute.limit
        assert_equal 20, verdict.day.limit
      end

      test "unauthenticated hits use the IP window and have no day window" do
        verdict = limiter.hit_unauthenticated("203.0.113.9")

        assert_equal 2, verdict.minute.limit
        assert_equal 1, verdict.minute.remaining
        assert_nil verdict.day

        limiter.hit_unauthenticated("203.0.113.9")
        assert limiter.hit_unauthenticated("203.0.113.9").exceeded?
        refute limiter.hit_unauthenticated("203.0.113.10").exceeded?
      end

      test "peek_unauthenticated reports without counting" do
        assert_equal 2, limiter.peek_unauthenticated("203.0.113.9").minute.remaining
        assert_equal 2, limiter.peek_unauthenticated("203.0.113.9").minute.remaining

        2.times { limiter.hit_unauthenticated("203.0.113.9") }

        peek = limiter.peek_unauthenticated("203.0.113.9")
        assert peek.exceeded?
        assert_equal 0, peek.minute.remaining
      end

      test "a store that fails its increment fails open" do
        # ActiveSupport::Cache::RedisCacheStore#increment runs inside Rails' failsafe,
        # which swallows a Redis outage and returns nil instead of raising. A nil count
        # must not turn into a 500 for every authenticated (or unauthenticated) request.
        @store.stubs(:increment).returns(nil)

        verdict = limiter.hit(@member)
        refute verdict.exceeded?
        assert_equal 3, verdict.minute.remaining

        verdict = limiter.hit_unauthenticated("203.0.113.9")
        refute verdict.exceeded?
        assert_equal 2, verdict.minute.remaining
      end

      # IP windows and connector-range budgets (MCP OAuth, spec D13).
      def ip_config
        config = ActiveSupport::OrderedOptions.new
        config.rate_limits = @config.rate_limits
        config.unauthenticated_per_minute = 60
        config.oauth_register_per_minute = 10
        config.oauth_token_per_minute = 30
        config.connector_egress_ranges = {anthropic: %w[160.79.104.0/21 153.61.208.0/20]}
        config.connector_range_per_minute = {unauthenticated: 3_000, oauth_register: 600, oauth_token: 3_000}
        config
      end

      def ip_limiter(now: NOW) = RateLimiter.new(now: now, store: @store, config: ip_config)

      test "addresses inside a connector range share one counter with the range limit" do
        first = ip_limiter.hit_ip(:unauthenticated, "160.79.104.9")
        second = ip_limiter.hit_ip(:unauthenticated, "160.79.111.200")
        third = ip_limiter.hit_ip(:unauthenticated, "153.61.208.1")

        assert_equal 3_000, first.minute.limit
        assert_equal [2_999, 2_998, 2_997], [first, second, third].map { |v| v.minute.remaining }
      end

      test "an address just outside the range has its own per-IP window" do
        2.times { ip_limiter.hit_ip(:unauthenticated, "160.79.104.9") }

        outside = ip_limiter.hit_ip(:unauthenticated, "160.79.112.1")

        assert_equal 60, outside.minute.limit
        assert_equal 59, outside.minute.remaining
      end

      test "the range counter is keyed by range name and window" do
        ip_limiter.hit_ip(:oauth_token, "160.79.104.9")

        assert_equal 1, @store.read("api:rl:oauth_token:range:anthropic:m:#{Time.utc(2026, 9, 13, 10, 30, 0).to_i}", raw: true).to_i
        assert_nil @store.read("api:rl:unauthenticated:range:anthropic:m:#{Time.utc(2026, 9, 13, 10, 30, 0).to_i}", raw: true)
      end

      test "a range exceeds only past its own limit" do
        config = ip_config
        config.connector_range_per_minute = {unauthenticated: 3, oauth_register: 600, oauth_token: 3_000}
        limiter = RateLimiter.new(now: NOW, store: @store, config: config)

        3.times { refute limiter.hit_ip(:unauthenticated, "160.79.104.9").exceeded? }
        assert limiter.hit_ip(:unauthenticated, "160.79.104.10").exceeded?
      end

      test "register is exceeded on the eleventh hit from one address" do
        10.times { refute ip_limiter.hit_ip(:oauth_register, "203.0.113.9").exceeded? }

        assert ip_limiter.hit_ip(:oauth_register, "203.0.113.9").exceeded?
        refute ip_limiter.hit_ip(:oauth_register, "203.0.113.10").exceeded?
      end

      test "the token window allows thirty per address" do
        verdict = ip_limiter.hit_ip(:oauth_token, "203.0.113.9")

        assert_equal 30, verdict.minute.limit
        assert_nil verdict.day
      end

      test "windows do not share counters for one address" do
        10.times { ip_limiter.hit_ip(:oauth_register, "203.0.113.9") }

        assert_equal 29, ip_limiter.hit_ip(:oauth_token, "203.0.113.9").minute.remaining
        assert_equal 59, ip_limiter.hit_ip(:unauthenticated, "203.0.113.9").minute.remaining
      end

      test "the unauthenticated window keeps its original per-IP key" do
        ip_limiter.hit_ip(:unauthenticated, "203.0.113.9")
        ip_limiter.hit_unauthenticated("203.0.113.9")

        assert_equal 2, @store.read("api:rl:anon:203.0.113.9:m:#{Time.utc(2026, 9, 13, 10, 30, 0).to_i}", raw: true).to_i
      end

      test "peek_ip reports a range without counting" do
        assert_equal 3_000, ip_limiter.peek_ip(:unauthenticated, "160.79.104.9").minute.remaining
        assert_equal 3_000, ip_limiter.peek_ip(:unauthenticated, "160.79.104.9").minute.remaining

        ip_limiter.hit_ip(:unauthenticated, "160.79.104.9")

        assert_equal 2_999, ip_limiter.peek_ip(:unauthenticated, "160.79.104.200").minute.remaining
      end

      test "peek_ip sees an exceeded per-IP window" do
        9.times { ip_limiter.hit_ip(:oauth_register, "203.0.113.9") }
        refute ip_limiter.peek_ip(:oauth_register, "203.0.113.9").exceeded?

        ip_limiter.hit_ip(:oauth_register, "203.0.113.9")

        assert ip_limiter.peek_ip(:oauth_register, "203.0.113.9").exceeded?
      end

      test "a malformed address falls back to the per-IP key" do
        verdict = ip_limiter.hit_ip(:oauth_register, "not-an-ip")

        assert_equal 10, verdict.minute.limit
        assert_equal 9, verdict.minute.remaining
        assert_equal 10, ip_limiter.hit_ip(:oauth_register, "").minute.limit
        assert_equal 10, ip_limiter.hit_ip(:oauth_register, nil).minute.limit
      end

      test "an IPv4-mapped IPv6 address inside a range counts toward the range" do
        assert_equal 3_000, ip_limiter.hit_ip(:unauthenticated, "::ffff:160.79.104.9").minute.limit
      end

      test "an IPv6 address matches no IPv4 range" do
        assert_equal 60, ip_limiter.hit_ip(:unauthenticated, "2001:db8::1").minute.limit
      end

      test "a config without connector ranges uses the per-IP window for every address" do
        verdict = limiter.hit_ip(:unauthenticated, "160.79.104.9")

        assert_equal 2, verdict.minute.limit
      end

      test "an unknown window is refused" do
        assert_raises(KeyError) { ip_limiter.hit_ip(:bogus, "203.0.113.9") }
      end

      test "a store that fails its increment fails open on IP windows" do
        @store.stubs(:increment).returns(nil)

        verdict = ip_limiter.hit_ip(:oauth_register, "203.0.113.9")

        refute verdict.exceeded?
        assert_equal 10, verdict.minute.remaining
      end

      test "the IP window class methods use the app's store and config" do
        verdict = RateLimiter.hit_ip(:oauth_register, "203.0.113.77")

        assert_equal Rails.application.config.x.api.oauth_register_per_minute, verdict.minute.limit
        assert_equal Rails.application.config.x.api.oauth_register_per_minute - 1, RateLimiter.peek_ip(:oauth_register, "203.0.113.77").minute.remaining
      end

      test "the class methods use the app's store and config" do
        verdict = RateLimiter.hit(@member)

        assert_equal Rails.application.config.x.api.rate_limits[:member][:per_minute], verdict.minute.limit
      end
    end
  end
end
