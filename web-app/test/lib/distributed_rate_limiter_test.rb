# frozen_string_literal: true

require "test_helper"

class DistributedRateLimiterTest < ActiveSupport::TestCase
  # Use a simple wrapper instead of connection pool mocking
  # This avoids issues with Mocha's yields behavior
  class MockRedisPool
    attr_reader :redis

    def initialize(redis)
      @redis = redis
    end

    def with
      yield @redis
    end

    def respond_to?(method, include_private = false)
      method.to_sym == :with || super
    end
  end

  def setup
    @redis = mock("redis")
    @pool = MockRedisPool.new(@redis)
  end

  # Initialization tests

  test "initializes with required parameters" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 10,
      window: 5.0,
      redis: @pool
    )

    assert_equal "test:api", limiter.key
    assert_equal 10, limiter.limit
    assert_equal 5.0, limiter.window
    assert_equal :blocking, limiter.mode
  end

  test "initializes with custom mode" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 10,
      window: 5.0,
      mode: :immediate,
      redis: @pool
    )

    assert_equal :immediate, limiter.mode
  end

  test "raises ArgumentError for missing key" do
    assert_raises(ArgumentError) do
      DistributedRateLimiter.new(key: nil, limit: 10, window: 1.0, redis: @pool)
    end

    assert_raises(ArgumentError) do
      DistributedRateLimiter.new(key: "", limit: 10, window: 1.0, redis: @pool)
    end
  end

  test "raises ArgumentError for invalid limit" do
    assert_raises(ArgumentError) do
      DistributedRateLimiter.new(key: "test", limit: 0, window: 1.0, redis: @pool)
    end

    assert_raises(ArgumentError) do
      DistributedRateLimiter.new(key: "test", limit: -1, window: 1.0, redis: @pool)
    end
  end

  test "raises ArgumentError for invalid window" do
    assert_raises(ArgumentError) do
      DistributedRateLimiter.new(key: "test", limit: 10, window: 0, redis: @pool)
    end

    assert_raises(ArgumentError) do
      DistributedRateLimiter.new(key: "test", limit: 10, window: -1, redis: @pool)
    end
  end

  test "raises ArgumentError for invalid mode" do
    assert_raises(ArgumentError) do
      DistributedRateLimiter.new(key: "test", limit: 10, window: 1.0, mode: :invalid, redis: @pool)
    end
  end

  # acquire! blocking mode tests

  test "acquire! allows request when under limit in blocking mode" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      mode: :blocking,
      redis: @pool
    )

    @redis.expects(:evalsha).returns([1, 3, 0])

    result = limiter.acquire!

    assert_equal true, result[:allowed]
    assert_equal 3, result[:remaining]
    assert_equal 0.0, result[:retry_after]
  end

  test "acquire! blocks and retries when limit exceeded in blocking mode" do
    # First call: limit exceeded, retry_after=850ms
    # Second call: allowed
    call_count = sequence("evalsha_calls")
    @redis.expects(:evalsha).returns([0, 0, 850]).once.in_sequence(call_count)
    @redis.expects(:evalsha).returns([1, 3, 0]).once.in_sequence(call_count)

    sleep_times = []
    DistributedRateLimiter.any_instance.stubs(:do_sleep).with { |t|
      sleep_times << t
      true
    }

    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      mode: :blocking,
      redis: @pool
    )

    result = limiter.acquire!

    assert_equal [0.85], sleep_times
    assert_equal true, result[:allowed]
    assert_equal 3, result[:remaining]
  end

  test "acquire! uses minimum sleep time to prevent spinning" do
    # First call: limit exceeded, retry_after=0ms (edge case)
    # Second call: allowed
    call_count = sequence("evalsha_calls")
    @redis.expects(:evalsha).returns([0, 0, 0]).once.in_sequence(call_count)
    @redis.expects(:evalsha).returns([1, 3, 0]).once.in_sequence(call_count)

    sleep_times = []
    DistributedRateLimiter.any_instance.stubs(:do_sleep).with { |t|
      sleep_times << t
      true
    }

    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      mode: :blocking,
      redis: @pool
    )

    limiter.acquire!

    # Should sleep for minimum 10ms even when retry_after is 0
    assert_equal [0.01], sleep_times
  end

  # acquire! immediate mode tests

  test "acquire! allows request when under limit in immediate mode" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      mode: :immediate,
      redis: @pool
    )

    @redis.expects(:evalsha).returns([1, 3, 0])

    result = limiter.acquire!

    assert_equal true, result[:allowed]
    assert_equal 3, result[:remaining]
  end

  test "acquire! raises exception when limit exceeded in immediate mode" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      mode: :immediate,
      redis: @pool
    )

    @redis.expects(:evalsha).returns([0, 0, 850])

    error = assert_raises(DistributedRateLimiter::RateLimitExceeded) do
      limiter.acquire!
    end

    assert_equal "test:api", error.key
    assert_equal 0.85, error.retry_after
    assert_match(/test:api/, error.message)
  end

  test "acquire! does not sleep in immediate mode" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      mode: :immediate,
      redis: @pool
    )

    @redis.expects(:evalsha).returns([0, 0, 500])
    limiter.expects(:do_sleep).never

    assert_raises(DistributedRateLimiter::RateLimitExceeded) do
      limiter.acquire!
    end
  end

  # check method tests

  test "check returns allowed when under limit" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      redis: @pool
    )

    # Mock: allowed, 2 remaining, no retry needed
    @redis.expects(:evalsha).returns([1, 2, 0])

    result = limiter.check

    assert_equal true, result[:allowed]
    assert_equal 2, result[:remaining]
    assert_equal 0.0, result[:retry_after]
  end

  test "check returns not allowed when at limit" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      redis: @pool
    )

    # Mock: not allowed, 0 remaining, retry after 150ms
    @redis.expects(:evalsha).returns([0, 0, 150])

    result = limiter.check

    assert_equal false, result[:allowed]
    assert_equal 0, result[:remaining]
    assert_equal 0.15, result[:retry_after]
  end

  test "check does not consume a slot" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      redis: @pool
    )

    # The consume flag (ARGV[3]) should be 0 for check (now_ms removed, uses Redis TIME)
    @redis.expects(:evalsha).with do |_sha, args|
      args[:argv][2] == 0  # consume flag is 0
    end.returns([1, 3, 0])

    limiter.check
  end

  # stats method tests

  test "stats returns current usage information" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 10,
      window: 5.0,
      redis: @pool
    )

    # Stats uses Redis server time and cleans up expired entries before counting
    @redis.expects(:time).returns([1234567890, 500000])
    @redis.expects(:zremrangebyscore).with("ratelimit:test:api", "-inf", anything)
    @redis.expects(:zcard).with("ratelimit:test:api").returns(7)

    result = limiter.stats

    assert_equal 7, result[:count]
    assert_equal 10, result[:limit]
    assert_equal 5.0, result[:window]
    assert_equal 3, result[:remaining]
  end

  test "stats handles empty state" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 10,
      window: 1.0,
      redis: @pool
    )

    # Stats uses Redis server time and cleans up expired entries before counting
    @redis.expects(:time).returns([1234567890, 500000])
    @redis.expects(:zremrangebyscore).with("ratelimit:test:api", "-inf", anything)
    @redis.expects(:zcard).returns(0)

    result = limiter.stats

    assert_equal 0, result[:count]
    assert_equal 10, result[:remaining]
  end

  # reset! method tests

  test "reset! clears all tracked requests" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      redis: @pool
    )

    @redis.expects(:del).with("ratelimit:test:api").returns(1)

    limiter.reset!
  end

  # RateLimitExceeded exception tests

  test "RateLimitExceeded exception includes retry_after and key" do
    error = DistributedRateLimiter::RateLimitExceeded.new(
      "Rate limit exceeded",
      key: "test:api",
      retry_after: 1.5
    )

    assert_equal 1.5, error.retry_after
    assert_equal "test:api", error.key
    assert_equal "Rate limit exceeded", error.message
  end

  # Error handling tests

  test "acquire! propagates Redis connection errors" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      redis: @pool
    )

    @redis.expects(:evalsha).raises(Redis::CannotConnectError)

    assert_raises(Redis::CannotConnectError) do
      limiter.acquire!
    end
  end

  test "acquire! handles NOSCRIPT error by falling back to eval" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      redis: @pool
    )

    # First call fails with NOSCRIPT
    @redis.expects(:evalsha).raises(Redis::CommandError.new("NOSCRIPT No matching script"))
    # Fallback to eval
    @redis.expects(:eval).returns([1, 3, 0])

    result = limiter.acquire!

    assert_equal true, result[:allowed]
  end

  test "acquire! re-raises non-NOSCRIPT Redis errors" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      redis: @pool
    )

    @redis.expects(:evalsha).raises(Redis::CommandError.new("ERR some other error"))

    assert_raises(Redis::CommandError) do
      limiter.acquire!
    end
  end

  # Timestamp and conversion tests

  test "converts window to milliseconds correctly" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.5,  # 1.5 seconds
      redis: @pool
    )

    # Verify window is sent as 1500ms to Lua script
    @redis.expects(:evalsha).with do |_sha, args|
      args[:argv][1] == 1500  # window_ms
    end.returns([1, 3, 0])

    limiter.acquire!
  end

  test "converts retry_after from milliseconds to seconds" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      mode: :immediate,
      redis: @pool
    )

    # Lua returns 2500ms
    @redis.expects(:evalsha).returns([0, 0, 2500])

    error = assert_raises(DistributedRateLimiter::RateLimitExceeded) do
      limiter.acquire!
    end

    # Converted to 2.5 seconds
    assert_equal 2.5, error.retry_after
  end

  # Lua script caching tests

  test "caches Lua script SHA across calls" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      redis: @pool
    )

    sha = Digest::SHA1.hexdigest(DistributedRateLimiter::LUA_SCRIPT)

    # Both calls should use the same SHA
    @redis.expects(:evalsha).with(sha, anything).returns([1, 3, 0]).twice

    limiter.acquire!
    limiter.acquire!
  end

  # Redis key format tests

  test "uses correct Redis key format" do
    limiter = DistributedRateLimiter.new(
      key: "igdb:api",
      limit: 4,
      window: 1.0,
      redis: @pool
    )

    @redis.expects(:evalsha).with do |_sha, args|
      args[:keys] == ["ratelimit:igdb:api"]
    end.returns([1, 3, 0])

    limiter.acquire!
  end

  # Direct Redis connection tests (without pool)

  test "works with direct Redis connection" do
    redis = mock("redis")
    redis.stubs(:respond_to?).with(:with).returns(false)

    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      redis: redis
    )

    redis.expects(:evalsha).returns([1, 3, 0])

    result = limiter.acquire!

    assert_equal true, result[:allowed]
  end

  # Edge case tests

  test "works with very small windows" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 0.001,  # 1ms window
      redis: @pool
    )

    # Window converted to 1ms
    @redis.expects(:evalsha).with do |_sha, args|
      args[:argv][1] == 1
    end.returns([1, 3, 0])

    limiter.acquire!
  end

  test "works with large limits" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 1000,
      window: 60.0,
      redis: @pool
    )

    @redis.expects(:evalsha).returns([1, 999, 0])

    result = limiter.acquire!

    assert_equal 999, result[:remaining]
  end

  test "handles zero retry_after in result" do
    limiter = DistributedRateLimiter.new(
      key: "test:api",
      limit: 4,
      window: 1.0,
      redis: @pool
    )

    @redis.expects(:evalsha).returns([1, 0, 0])

    result = limiter.acquire!

    assert_equal 0.0, result[:retry_after]
  end
end
