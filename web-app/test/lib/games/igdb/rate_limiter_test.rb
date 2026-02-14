# frozen_string_literal: true

require "test_helper"

class Games::Igdb::RateLimiterTest < ActiveSupport::TestCase
  test "allows requests within rate limit" do
    limiter = Games::Igdb::RateLimiter.new

    # Should allow 4 requests without sleeping
    assert_nothing_raised do
      4.times { limiter.wait! }
    end
  end

  test "enforces 4 requests per second" do
    limiter = Games::Igdb::RateLimiter.new

    # Fill the bucket
    4.times { limiter.wait! }

    # 5th request should sleep
    limiter.expects(:sleep).with(anything)
    limiter.wait!
  end

  test "is thread-safe" do
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
end
