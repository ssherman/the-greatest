# frozen_string_literal: true

module Books
  module OpenLibrary
    # Redis-backed circuit breaker for the Open Library service client.
    # Rails.cache is :null_store in test and :memory_store in development, so
    # it cannot carry breaker state across processes; state lives in Redis
    # instead, under one hash key with an expiry >= the cooldown so a dead
    # process cannot wedge the breaker open forever.
    class CircuitBreaker
      def initialize(key:, failure_threshold:, cooldown:, redis: nil)
        @key = key
        @failure_threshold = failure_threshold
        @cooldown = cooldown
        @redis_pool = redis || REDIS_POOL
      end

      # Runs the block while the circuit is closed or half-open (cooldown
      # elapsed). Raises Exceptions::CircuitOpenError without invoking the
      # block while the circuit is open. Which errors count is up to the
      # caller: whatever the block raises increments the failure count.
      def call
        raise Exceptions::CircuitOpenError, "circuit open for '#{@key}'" if open?

        begin
          result = yield
        rescue
          record_failure
          raise
        end

        reset!
        result
      end

      def open?
        opened_at = read_opened_at
        opened_at && !cooldown_elapsed?(opened_at)
      end

      def reset!
        with_redis { |redis| redis.del(redis_key) }
      end

      private

      def record_failure
        with_redis do |redis|
          failures = redis.hincrby(redis_key, "failures", 1)
          redis.hset(redis_key, "opened_at", Time.current.to_f.to_s) if failures >= @failure_threshold
          redis.expire(redis_key, @cooldown)
        end
      end

      def read_opened_at
        with_redis do |redis|
          redis.hgetall(redis_key)["opened_at"]&.to_f
        end
      end

      def cooldown_elapsed?(opened_at)
        Time.current.to_f - opened_at >= @cooldown
      end

      def redis_key
        "circuit:#{@key}"
      end

      def with_redis(&block)
        if @redis_pool.respond_to?(:with)
          @redis_pool.with(&block)
        else
          yield @redis_pool
        end
      end
    end
  end
end
