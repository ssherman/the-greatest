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

      test "the class methods use the app's store and config" do
        verdict = RateLimiter.hit(@member)

        assert_equal Rails.application.config.x.api.rate_limits[:member][:per_minute], verdict.minute.limit
      end
    end
  end
end
