# frozen_string_literal: true

require "test_helper"

module Books
  module OpenLibrary
    class CircuitBreakerTest < ActiveSupport::TestCase
      include ActiveSupport::Testing::TimeHelpers

      # FakeRedis lives in test/support/books/open_library/fake_redis.rb
      # (required from test_helper.rb) -- shared with base_client_test.rb.

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

      # R118 (Codex, PR #315): record_failure expired both `failures` and
      # `opened_at` exactly when the cooldown ended. A failing half-open
      # probe then restarted `hincrby` at 1, so the circuit stayed closed
      # and permitted more requests during a continuing outage. Masked
      # before this fix by FakeRedis#expire being a no-op.

      test "R118: a failed half-open probe re-opens the circuit, and the next call raises CircuitOpenError without invoking the block" do
        3.times do
          assert_raises(RuntimeError) { @breaker.call { raise "boom" } }
        end

        travel_to(61.seconds.from_now) do
          assert_raises(RuntimeError) { @breaker.call { raise "boom again" } }
          assert @breaker.open?

          invoked = false
          assert_raises(Books::OpenLibrary::Exceptions::CircuitOpenError) do
            @breaker.call { invoked = true }
          end
          assert_not invoked
        end
      end

      test "R118: accumulated sub-threshold failure state survives past one cooldown (expiry is 2x cooldown)" do
        2.times do
          assert_raises(RuntimeError) { @breaker.call { raise "boom" } }
        end
        assert_not @breaker.open?

        travel_to(61.seconds.from_now) do
          assert_raises(RuntimeError) { @breaker.call { raise "boom again" } }
          assert @breaker.open?
        end
      end

      test "R118: a dead process's state clears after two full cooldowns of silence, so one failure does not re-open it" do
        3.times do
          assert_raises(RuntimeError) { @breaker.call { raise "boom" } }
        end

        travel_to(121.seconds.from_now) do
          assert_not @breaker.open?

          assert_raises(RuntimeError) { @breaker.call { raise "boom" } }
          assert_not @breaker.open?
        end
      end

      test "FakeRedis#expire actually drops the key once its TTL elapses" do
        redis = FakeRedis.new
        redis.hset("k", "f", "v")
        redis.expire("k", 60)

        travel_to(61.seconds.from_now) do
          assert_equal({}, redis.hgetall("k"))
        end
      end
    end
  end
end
