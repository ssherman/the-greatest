# frozen_string_literal: true

require "test_helper"

class Viaf::RateLimiterTest < ActiveSupport::TestCase
  test "delegates to DistributedRateLimiter with spacing configuration" do
    underlying = mock("distributed_limiter")
    underlying.expects(:acquire!).returns({allowed: true, remaining: 1, retry_after: 0.0})

    DistributedRateLimiter.expects(:new).with(
      key: "viaf:api",
      limit: 2,
      window: 60.0,
      mode: :blocking
    ).returns(underlying)

    Viaf::RateLimiter.new.wait!
  end

  test "supports immediate mode" do
    underlying = mock("distributed_limiter")
    underlying.stubs(:acquire!).returns({allowed: true, remaining: 1, retry_after: 0.0})

    DistributedRateLimiter.expects(:new).with(
      key: "viaf:api",
      limit: 2,
      window: 60.0,
      mode: :immediate
    ).returns(underlying)

    Viaf::RateLimiter.new(mode: :immediate).wait!
  end

  test "propagates RateLimitExceeded from the underlying limiter" do
    underlying = mock("distributed_limiter")
    underlying.stubs(:acquire!).raises(
      DistributedRateLimiter::RateLimitExceeded.new("nope", key: "viaf:api", retry_after: 5.0)
    )
    DistributedRateLimiter.stubs(:new).returns(underlying)

    assert_raises(DistributedRateLimiter::RateLimitExceeded) do
      Viaf::RateLimiter.new(mode: :immediate).wait!
    end
  end
end
