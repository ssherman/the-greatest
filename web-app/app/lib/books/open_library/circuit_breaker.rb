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
      #
      # `opened_at` is read exactly once, before the attempt, so the
      # half-open/closed classification is fixed for the whole call even if
      # the key's state changes (or expires) while the block runs.
      def call
        opened_at = read_opened_at
        raise Exceptions::CircuitOpenError, "circuit open for '#{@key}'" if opened_at && !cooldown_elapsed?(opened_at)

        half_open = !opened_at.nil?

        begin
          result = yield
        rescue
          half_open ? reopen_after_failed_probe! : record_failure
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
          redis.expire(redis_key, state_ttl)
        end
      end

      # R118 (Codex, PR #315): a failed half-open probe proves the outage is
      # still live, so the circuit must re-open unconditionally -- even if
      # the stored counter expired between the read in #call and this write,
      # in which case a plain hincrby would restart at 1 and never reach
      # the threshold. `half_open` in #call already carries the knowledge
      # that this was a probe, not a fresh accumulation, so failures is
      # forced up to at least the threshold and opened_at is stamped now
      # regardless of what hincrby returns.
      def reopen_after_failed_probe!
        with_redis do |redis|
          failures = redis.hincrby(redis_key, "failures", 1)
          redis.hset(redis_key, "failures", [failures, @failure_threshold].max.to_s)
          redis.hset(redis_key, "opened_at", Time.current.to_f.to_s)
          redis.expire(redis_key, state_ttl)
        end
      end

      # State outlives the half-open window itself (one @cooldown) so that
      # opened_at is still readable at the instant the cooldown ends,
      # whenever the next call actually arrives -- otherwise a probe that
      # shows up right as the key expires reads a blank hash, is treated as
      # a fresh closed breaker instead of a half-open probe, and a failure
      # never re-opens the circuit (this was R118). A dead process still
      # cannot wedge the breaker open forever: with no calls at all, the key
      # is gone after two cooldowns of silence.
      def state_ttl
        @cooldown * 2
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
