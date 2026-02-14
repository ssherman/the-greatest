# frozen_string_literal: true

require "test_helper"

class Games::Igdb::RateLimiterTest < ActiveSupport::TestCase
  test "allows requests within rate limit" do
    underlying = mock("distributed_limiter")
    underlying.stubs(:acquire!).returns({
      allowed: true,
      remaining: 3,
      retry_after: 0.0
    })

    DistributedRateLimiter.stubs(:new).returns(underlying)

    limiter = Games::Igdb::RateLimiter.new

    assert_nothing_raised do
      4.times { limiter.wait! }
    end
  end

  test "delegates to DistributedRateLimiter with correct configuration" do
    underlying = mock("distributed_limiter")
    underlying.expects(:acquire!).returns({allowed: true, remaining: 3, retry_after: 0.0})

    DistributedRateLimiter.expects(:new).with(
      key: "igdb:api",
      limit: 4,
      window: 1.0,
      mode: :blocking
    ).returns(underlying)

    limiter = Games::Igdb::RateLimiter.new
    limiter.wait!
  end

  test "supports immediate mode" do
    underlying = mock("distributed_limiter")

    DistributedRateLimiter.expects(:new).with(
      key: "igdb:api",
      limit: 4,
      window: 1.0,
      mode: :immediate
    ).returns(underlying)

    Games::Igdb::RateLimiter.new(mode: :immediate)
  end

  test "wait! calls acquire! on underlying limiter" do
    underlying = mock("distributed_limiter")
    underlying.expects(:acquire!).returns({allowed: true, remaining: 3, retry_after: 0.0})

    DistributedRateLimiter.stubs(:new).returns(underlying)

    limiter = Games::Igdb::RateLimiter.new
    result = limiter.wait!

    assert_equal true, result[:allowed]
  end

  test "is thread-safe via DistributedRateLimiter" do
    underlying = mock("distributed_limiter")
    underlying.stubs(:acquire!).returns({
      allowed: true,
      remaining: 3,
      retry_after: 0.0
    })

    DistributedRateLimiter.stubs(:new).returns(underlying)

    limiter = Games::Igdb::RateLimiter.new
    errors = []

    threads = 4.times.map do
      Thread.new do
        limiter.wait!
      rescue => e
        errors << e
      end
    end

    threads.each(&:join)
    assert_empty errors
  end

  test "REQUESTS_PER_SECOND constant is 4" do
    assert_equal 4, Games::Igdb::RateLimiter::REQUESTS_PER_SECOND
  end
end
