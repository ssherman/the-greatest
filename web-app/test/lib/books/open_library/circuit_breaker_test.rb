# frozen_string_literal: true

require "test_helper"

module Books
  module OpenLibrary
    class CircuitBreakerTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      # Implements only the Redis hash commands the breaker issues, backed by a
      # plain Hash, with redis-rb's return types (strings from hgetall, integers
      # from hincrby) so these tests exercise real breaker behaviour. CI has no
      # Redis service, so REDIS_POOL must never be touched here.
      class FakeRedis
        def initialize
          @data = {}
        end

        def hgetall(key)
          (@data[key] || {}).dup
        end

        def hincrby(key, field, amount)
          hash = (@data[key] ||= {})
          new_value = (hash[field] || "0").to_i + amount
          hash[field] = new_value.to_s
          new_value
        end

        def hset(key, field, value)
          hash = (@data[key] ||= {})
          hash[field] = value.to_s
        end

        def expire(key, _seconds)
          true
        end

        def del(key)
          @data.delete(key) ? 1 : 0
        end
      end

      def setup
        @redis = FakeRedis.new
        @breaker = Books::OpenLibrary::CircuitBreaker.new(
          key: "test:open_library",
          failure_threshold: 3,
          cooldown: 60,
          redis: @redis
        )
      end

      teardown do
        travel_back
      end

      test "a successful call passes the block's return value through" do
        result = @breaker.call { "ok" }

        assert_equal "ok", result
      end

      test "failures below the threshold re-raise the original error and leave the breaker closed" do
        2.times do
          error = assert_raises(RuntimeError) { @breaker.call { raise "boom" } }
          assert_equal "boom", error.message
        end

        assert_not @breaker.open?
      end

      test "the threshold-th consecutive failure opens the breaker" do
        3.times do
          assert_raises(RuntimeError) { @breaker.call { raise "boom" } }
        end

        assert @breaker.open?
      end

      test "while open, call raises CircuitOpenError without invoking the block" do
        3.times do
          assert_raises(RuntimeError) { @breaker.call { raise "boom" } }
        end
        invoked = false

        assert_raises(Books::OpenLibrary::Exceptions::CircuitOpenError) do
          @breaker.call { invoked = true }
        end

        assert_not invoked
      end

      test "after the cooldown elapses the next call is attempted again" do
        3.times do
          assert_raises(RuntimeError) { @breaker.call { raise "boom" } }
        end

        travel_to(61.seconds.from_now) do
          invoked = false

          result = @breaker.call {
            invoked = true
            "recovered"
          }

          assert invoked
          assert_equal "recovered", result
        end
      end

      test "a successful half-open call resets the failure count" do
        3.times do
          assert_raises(RuntimeError) { @breaker.call { raise "boom" } }
        end

        travel_to(61.seconds.from_now) do
          @breaker.call { "recovered" }
        end

        assert_not @breaker.open?
      end

      test "a failed half-open call re-opens the breaker instead of clearing it" do
        3.times do
          assert_raises(RuntimeError) { @breaker.call { raise "boom" } }
        end

        travel_to(61.seconds.from_now) do
          assert_raises(RuntimeError) { @breaker.call { raise "boom again" } }
          assert @breaker.open?
        end
      end

      test "reset! closes the breaker for a fresh call" do
        3.times do
          assert_raises(RuntimeError) { @breaker.call { raise "boom" } }
        end

        @breaker.reset!

        assert_not @breaker.open?
        assert_equal "ok", @breaker.call { "ok" }
      end
    end
  end
end
